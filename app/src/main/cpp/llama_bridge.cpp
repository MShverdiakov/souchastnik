// Соучастник -- нативный мост к llama.cpp.
//
// Задача узкая: получить строку, которую человек печатает, и выбрать ОДИН
// вариант из закрытого списка (код статьи-кандидата либо "none").
//
// ПОЧЕМУ НЕ GBNF-ГРАММАТИКА. Первая версия зажимала вывод грамматикой на
// перечень кодов ("5.61" | "158" | ...). Замер на десктопе (x64, 4 потока):
//
//     без грамматики          sampling =   2.3 мс
//     грамматика, 1 токен     sampling = 325.8 мс
//     грамматика, 3 токена    sampling = 571.9 мс
//
// Грамматический сэмплер обходит весь словарь -- у Qwen3.5 это 248 320
// токенов -- на каждом шаге. Для закрытого списка из нескольких строк это
// лишнее: варианты можно токенизировать заранее и на каждом шаге брать
// argmax только по тем токенам, которыми хоть один живой вариант может
// продолжиться. Это десяток сравнений вместо четверти миллиона, результат
// тот же, что у грамматики с жадным сэмплингом.
//
// ПОЧЕМУ НЕ ОДНОТОКЕННЫЕ МЕТКИ. Предыдущая ревизия обозначала каждую статью
// одним символом и делала argmax по 83 логитам за один проход префилла --
// быстро, но проверялось это только на десктопе через tools/try.py
// --mode prod, где и записано: без обученной LoRA режим выдаёт мусор.
// Замер на устройстве это подтвердил: модель на каждой фразе выдавала '<',
// то есть первый символ '<think>', которым Qwen3.5 начинает ЛЮБОЙ ответ.
// Метку '<' носит статья 280.4, поэтому мусор выглядел как вердикт.
//
// ОТСЮДА ГЛАВНОЕ: Qwen3.5 -- инструктивная гибридная reasoning-модель, и
// сырым промптом её дёргать нельзя. Промпт обязан идти через чат-шаблон,
// причём с ЗАКРЫТЫМ блоком рассуждения: шаблон из GGUF при
// enable_thinking=false дописывает "<think>\n\n</think>\n\n" после реплики
// ассистента. Без этого ответы схлопываются в одну статью на всё.

#include <jni.h>
#include <android/log.h>
#include <dirent.h>
#include <dlfcn.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <exception>
#include <mutex>
#include <string>
#include <vector>

#include "ggml-backend.h"
#include "llama.h"

#define TAG "souchastnik-native"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO,  TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)

void llama_android_log(enum ggml_log_level level, const char * text, void *) {
    android_LogPriority prio = ANDROID_LOG_INFO;
    switch (level) {
        case GGML_LOG_LEVEL_ERROR: prio = ANDROID_LOG_ERROR; break;
        case GGML_LOG_LEVEL_WARN:  prio = ANDROID_LOG_WARN;  break;
        case GGML_LOG_LEVEL_DEBUG: prio = ANDROID_LOG_DEBUG; break;
        default: break;
    }
    const char * tag = TAG;
    if (text && std::strstr(text, "ggml-hex")) tag = "ggml-hex";
    __android_log_print(prio, tag, "%s", text ? text : "");
}

namespace {

using steady = std::chrono::steady_clock;

long ms_since(steady::time_point t0) {
    return (long) std::chrono::duration_cast<std::chrono::milliseconds>(
        steady::now() - t0).count();
}

// Системное сообщение судьи -- это таблица статей-кандидатов плюс инструкции,
// у калитки свой промпт на два десятка строк. Прежние 512 на это не влезают.
// Цена -- байты состояния из бюджета RSS, поэтому не больше, чем нужно.
constexpr int N_CTX = 1024;

// Сколько токенов оставляем под ответ и служебные хвосты при обрезке.
constexpr int N_RESERVE = 16;

// Куски чат-шаблона Qwen3.5 (tokenizer.chat_template в GGUF), развёрнутые
// для случая "system + user, add_generation_prompt=true, enable_thinking=false".
// Развёрнуты руками намеренно: тянуть в APK Jinja-движок ради двух сообщений
// незачем, а llama_chat_apply_template из C API не принимает
// chat_template_kwargs и открытый <think> не закроет.
constexpr const char * TPL_SYS_OPEN  = "<|im_start|>system\n";
constexpr const char * TPL_SYS_CLOSE = "<|im_end|>\n<|im_start|>user\n";
constexpr const char * TPL_TAIL      =
    "<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n";

struct Engine {
    llama_model   * model = nullptr;
    llama_context * ctx   = nullptr;
    const llama_vocab * vocab = nullptr;

    llama_token eos = 0;

    // Выставляется из cancel() и читается abort-колбэком llama.cpp:
    // пользователь нажал следующую клавишу -- текущий разбор не нужен.
    std::atomic<bool> abort_flag{false};

    // Снимок состояния после системной реплики (head). Пока человек дописывает
    // ту же фразу, набор статей не меняется -- head тот же, и префилл ~300
    // токенов судьи можно не гонять заново. ~20 МБ GDN+KV, в памяти процесса.
    std::vector<llama_token> prefix_toks;
    std::vector<uint8_t>     prefix_state;
    llama_state_seq_flags    prefix_flags = LLAMA_STATE_SEQ_FLAGS_NONE;
};

bool abort_cb(void * data) {
    Engine * e = static_cast<Engine *>(data);
    return e->abort_flag.load(std::memory_order_relaxed);
}

std::string jstr(JNIEnv * env, jstring s) {
    if (!s) return std::string();
    const char * c = env->GetStringUTFChars(s, nullptr);
    std::string out = c ? c : "";
    env->ReleaseStringUTFChars(s, c);
    return out;
}

// Имя загруженного варианта ggml-cpu ("android_armv8.2_2"); пусто, пока не
// загружен. Бэкенд один на процесс, поэтому статик, а не поле Engine.
std::string g_cpu_backend;
// Куда уехали слои после последнего init: "HTP0" или "cpu".
std::string g_accel = "cpu";
bool        g_hexagon_ok = false;

// Выбирает и грузит вариант ядер ggml-cpu под этот процессор.
//
// ggml собран с GGML_BACKEND_DL + GGML_CPU_ALL_VARIANTS (build.gradle.kts):
// рядом с libsouchastnik.so лежат семь libggml-cpu-android_<arch>.so, от
// armv8.0 без dotprod до armv9.2 с SME. У каждого есть ggml_backend_score():
// 0 -- этому CPU не подходит (проверяется по getauxval(AT_HWCAP), сам вызов
// безопасен на любом ядре), иначе -- чем богаче набор инструкций, тем выше.
//
// Не ggml_backend_load_all_from_path(): та сканирует каталог по разу на
// каждый из пятнадцати бэкендов (CUDA, Vulkan, ...) и не говорит, что в итоге
// выбрала. Нам нужно имя варианта в лог и в бенч: именно оно объясняет,
// почему на Kirin 710 разбор идёт 20+ секунд, а на Dimensity 700 -- 4.
//
// Зависимость libggml-base.so вариантам dlopen находит среди уже
// загруженных: её притащил System.loadLibrary("souchastnik").
//
// @return имя варианта без префикса/суффикса или пустая строка при провале.
std::string load_cpu_backend(const std::string & dir) {
    const std::string prefix = "libggml-cpu-";
    const std::string suffix = ".so";

    DIR * d = opendir(dir.c_str());
    if (!d) {
        LOGE("каталог библиотек не открывается: %s", dir.c_str());
        return std::string();
    }

    int         best_score = 0;
    std::string best_path;
    std::string best_name;
    int         seen = 0;

    while (dirent * ent = readdir(d)) {
        const std::string name = ent->d_name;
        if (name.size() <= prefix.size() + suffix.size()) continue;
        if (name.compare(0, prefix.size(), prefix) != 0) continue;
        if (name.compare(name.size() - suffix.size(), suffix.size(), suffix) != 0) continue;
        ++seen;

        const std::string path = dir + "/" + name;
        void * h = dlopen(path.c_str(), RTLD_NOW | RTLD_LOCAL);
        if (!h) {
            LOGE("dlopen %s: %s", name.c_str(), dlerror());
            continue;
        }
        auto score_fn = reinterpret_cast<int (*)()>(dlsym(h, "ggml_backend_score"));
        const int score = score_fn ? score_fn() : -1;
        dlclose(h);
        LOGI("вариант ggml-cpu %s: score %d", name.c_str(), score);

        if (score > best_score) {
            best_score = score;
            best_path  = path;
            best_name  = name.substr(prefix.size(),
                                     name.size() - prefix.size() - suffix.size());
        }
    }
    closedir(d);

    if (best_score <= 0) {
        LOGE("ни один вариант ggml-cpu не подходит этому CPU (файлов %d в %s)",
             seen, dir.c_str());
        return std::string();
    }
    if (!ggml_backend_load(best_path.c_str())) {
        LOGE("ggml_backend_load(%s) не удался", best_path.c_str());
        return std::string();
    }
    LOGI("ggml-cpu: %s (score %d)", best_name.c_str(), best_score);
    return best_name;
}

void set_adsp_library_path(const std::string & lib_dir, const std::string & adsp_dir) {
    std::string path = lib_dir;
    if (!adsp_dir.empty()) {
        path += ";";
        path += adsp_dir;
    }
    path += ";/system/lib/rfsa/adsp;/system/vendor/lib/rfsa/adsp;/dsp";
    setenv("ADSP_LIBRARY_PATH", path.c_str(), 1);
    LOGI("ADSP_LIBRARY_PATH=%s", path.c_str());
}

std::string first_htp_device_name() {
    const size_t n = ggml_backend_dev_count();
    for (size_t i = 0; i < n; ++i) {
        ggml_backend_dev_t dev = ggml_backend_dev_get(i);
        const char * name = ggml_backend_dev_name(dev);
        LOGI("ggml device %zu: %s", i, name ? name : "?");
        if (name && std::strncmp(name, "HTP", 3) == 0) return name;
    }
    return std::string();
}

bool load_hexagon_backend(const std::string & dir) {
    const std::string path = dir + "/libggml-hexagon.so";
    if (!ggml_backend_load(path.c_str())) {
        LOGE("ggml_backend_load(%s) не удался", path.c_str());
        return false;
    }
    const std::string htp = first_htp_device_name();
    if (htp.empty()) {
        LOGE("libggml-hexagon загружен, но HTP-устройства нет");
        return false;
    }
    LOGI("ggml-hexagon: устройство %s", htp.c_str());
    return true;
}

bool ensure_hexagon(const std::string & lib_dir, const std::string & adsp_dir) {
    static std::mutex mu;
    static bool tried = false;
    std::lock_guard<std::mutex> lock(mu);
    if (tried) return g_hexagon_ok;
    tried = true;
    set_adsp_library_path(lib_dir, adsp_dir);
    try {
        g_hexagon_ok = load_hexagon_backend(lib_dir);
    } catch (const std::exception & ex) {
        LOGE("hexagon: %s", ex.what());
        g_hexagon_ok = false;
    } catch (...) {
        LOGE("hexagon: неизвестное исключение при загрузке");
        g_hexagon_ok = false;
    }
    return g_hexagon_ok;
}

std::vector<llama_token> tokenize(const llama_vocab * vocab,
                                  const std::string & text,
                                  bool add_special) {
    int n = -llama_tokenize(vocab, text.c_str(), (int32_t) text.size(),
                            nullptr, 0, add_special, /*parse_special*/ true);
    if (n <= 0) return std::vector<llama_token>();
    std::vector<llama_token> out(n);
    int got = llama_tokenize(vocab, text.c_str(), (int32_t) text.size(),
                             out.data(), n, add_special, true);
    if (got < 0) return std::vector<llama_token>();
    out.resize(got);
    return out;
}

// Сброс состояния между запросами. В новых ревизиях llama.cpp
// llama_kv_cache_clear заменён на llama_memory_clear -- и для гибридных
// моделей вроде Qwen3.5 сбрасывать надо именно через memory API,
// иначе рекуррентное состояние DeltaNet-слоёв переживёт запрос
// и следующий разбор поедет по контексту предыдущего.
void reset_state(Engine * e) {
    llama_memory_clear(llama_get_memory(e->ctx), /*data*/ true);
}

void prefix_clear(Engine * e) {
    e->prefix_toks.clear();
    e->prefix_state.clear();
    e->prefix_flags = LLAMA_STATE_SEQ_FLAGS_NONE;
}

bool decode_tokens(Engine * e, const llama_token * toks, int n) {
    if (n <= 0) return true;
    llama_batch b = llama_batch_get_one(const_cast<llama_token *>(toks), n);
    return llama_decode(e->ctx, b) == 0;
}

bool prefix_save(Engine * e, const std::vector<llama_token> & head) {
    llama_state_seq_flags flags = LLAMA_STATE_SEQ_FLAGS_NONE;
    size_t n = llama_state_seq_get_size_ext(e->ctx, 0, flags);
    if (n == 0) {
        prefix_clear(e);
        return false;
    }
    e->prefix_state.resize(n);
    size_t got = llama_state_seq_get_data_ext(e->ctx, e->prefix_state.data(), n, 0, flags);
    if (got == 0) {
        prefix_clear(e);
        return false;
    }
    e->prefix_state.resize(got);
    e->prefix_toks = head;
    e->prefix_flags = flags;
    LOGI("prompt cache SAVE %d токенов, %d байт", (int) head.size(), (int) got);
    return true;
}

bool prefix_restore(Engine * e) {
    if (e->prefix_state.empty()) return false;
    reset_state(e);
    size_t got = llama_state_seq_set_data_ext(
        e->ctx, e->prefix_state.data(), e->prefix_state.size(), 0, e->prefix_flags);
    if (got == 0) return false;
    const llama_pos pmax = llama_memory_seq_pos_max(llama_get_memory(e->ctx), 0);
    if (pmax + 1 != (llama_pos) e->prefix_toks.size()) {
        LOGE("prompt cache: pos_max %d, ждали %d",
             (int) pmax, (int) e->prefix_toks.size() - 1);
        return false;
    }
    return true;
}

struct Stats {
    long prompt_tokens = 0;
    long prefill_ms    = 0;
    long decode_ms     = 0;
    long gen_tokens    = 0;
    long cache_hit     = 0;
};

// Один разбор: собрать промпт по чат-шаблону, префиллить и выбрать один
// вариант из alts. Возвращает индекс выбранного варианта, -1 при ошибке
// или отмене.
//
// Варианты сравниваются пожадному, токен за токеном: на каждом шаге
// разрешены только те токены, которыми продолжается хотя бы один ещё живой
// вариант. Если какой-то вариант уже выбран целиком, к разрешённым
// добавляется признак конца -- иначе на списке вида {"207", "207.3"}
// короткий вариант был бы недостижим.
//
// first_bias прибавляется к логиту первого токена alts[0] на первом шаге.
// alts[0] -- это "none", и сдвиг задаёт порог «чисто»: при коротком списке
// кандидатов модель охотнее берёт статью, чем отвечает none, а пропущенная
// статья для шутки безвредна, ложная выглядит как поломка. Значение и
// таблица замеров -- у NONE_BIAS в LlamaBridge.kt. Это тот же argmax, что и
// раньше, просто с гирей на одной чаше: ни одного лишнего прохода модели
// сдвиг не стоит.
int decide(Engine * e,
           const std::string & system,
           const std::string & text,
           const std::vector<std::string> & alts,
           float first_bias,
           Stats * st) {
    if (alts.empty()) return -1;

    e->abort_flag.store(false);

    // Токенизируем кусками: между ними стоят спецтокены чат-шаблона, так что
    // BPE не сольёт токены через границу, а обрезать длинное сообщение можно
    // не трогая системную часть.
    const std::vector<llama_token> head =
        tokenize(e->vocab, std::string(TPL_SYS_OPEN) + system + TPL_SYS_CLOSE,
                 /*add_special*/ false);
    const std::vector<llama_token> tail =
        tokenize(e->vocab, TPL_TAIL, /*add_special*/ false);
    std::vector<llama_token> body = tokenize(e->vocab, text, /*add_special*/ false);

    if (head.empty() || tail.empty()) {
        LOGE("чат-шаблон не токенизировался");
        return -1;
    }

    const int budget = N_CTX - N_RESERVE - (int) head.size() - (int) tail.size();
    if (budget < 8) {
        LOGE("системное сообщение не влезает в контекст: %d токенов при N_CTX=%d",
             (int) head.size(), N_CTX);
        return -1;
    }
    if ((int) body.size() > budget) {
        // Человек пишет простыню -- берём хвост, там обычно и состав.
        body.erase(body.begin(), body.end() - budget);
    }

    std::vector<llama_token> rest;
    rest.reserve(body.size() + tail.size());
    rest.insert(rest.end(), body.begin(), body.end());
    rest.insert(rest.end(), tail.begin(), tail.end());

    if (st) st->prompt_tokens = (long) (head.size() + rest.size());

    steady::time_point t0 = steady::now();

    const bool cache_ok = e->prefix_toks == head && !e->prefix_state.empty()
        && prefix_restore(e);
    if (cache_ok) {
        if (st) st->cache_hit = 1;
        LOGI("prompt cache HIT head=%d rest=%d", (int) head.size(), (int) rest.size());
        if (!decode_tokens(e, rest.data(), (int) rest.size())) {
            if (e->abort_flag.load(std::memory_order_relaxed)) {
                LOGI("разбор отменён на префилле (cache hit, rest %d)", (int) rest.size());
            } else {
                LOGE("префилл хвоста не прошёл (cache hit, rest %d)", (int) rest.size());
                prefix_clear(e);
            }
            return -1;
        }
    } else {
        if (st) st->cache_hit = 0;
        reset_state(e);
        if (!decode_tokens(e, head.data(), (int) head.size())) {
            if (e->abort_flag.load(std::memory_order_relaxed)) {
                LOGI("разбор отменён на префилле head (%d)", (int) head.size());
            } else {
                LOGE("префилл head не прошёл (%d токенов)", (int) head.size());
            }
            prefix_clear(e);
            return -1;
        }
        if (e->abort_flag.load(std::memory_order_relaxed)) return -1;
        if (!prefix_save(e, head)) {
            LOGI("prompt cache: снимок head не сохранился, дальше без кэша");
        }
        if (!decode_tokens(e, rest.data(), (int) rest.size())) {
            if (e->abort_flag.load(std::memory_order_relaxed)) {
                LOGI("разбор отменён на префилле rest (%d)", (int) rest.size());
            } else {
                LOGE("префилл rest не прошёл (%d токенов)", (int) rest.size());
            }
            return -1;
        }
    }
    if (st) st->prefill_ms = ms_since(t0);
    if (e->abort_flag.load(std::memory_order_relaxed)) return -1;

    // Заранее разложенные варианты. Пустая токенизация означала бы вариант,
    // который модель не может произнести -- честнее упасть, чем молча его
    // никогда не выбирать.
    std::vector<std::vector<llama_token>> alt_toks(alts.size());
    for (size_t i = 0; i < alts.size(); ++i) {
        alt_toks[i] = tokenize(e->vocab, alts[i], /*add_special*/ false);
        if (alt_toks[i].empty()) {
            LOGE("вариант \"%s\" не токенизировался", alts[i].c_str());
            return -1;
        }
    }

    std::vector<int> alive(alts.size());
    for (size_t i = 0; i < alts.size(); ++i) alive[i] = (int) i;

    steady::time_point t1 = steady::now();
    size_t pos = 0;
    int chosen = -1;

    while (true) {
        if (e->abort_flag.load(std::memory_order_relaxed)) return -1;

        const float * logits = llama_get_logits_ith(e->ctx, -1);
        if (!logits) return -1;

        // Разрешённые продолжения и признак того, что какой-то вариант уже
        // набран целиком.
        std::vector<llama_token> allowed;
        bool complete = false;
        for (int i : alive) {
            if (pos < alt_toks[i].size()) {
                const llama_token t = alt_toks[i][pos];
                if (std::find(allowed.begin(), allowed.end(), t) == allowed.end()) {
                    allowed.push_back(t);
                }
            } else {
                complete = true;
            }
        }
        if (allowed.empty()) break;   // всё живое уже набрано целиком

        // Сдвиг порога действует только на первом шаге и только на первый
        // токен alts[0]: дальше выбор идёт уже внутри статей-кандидатов.
        const llama_token biased = (pos == 0) ? alt_toks[0][0] : -1;
        auto score = [&](llama_token t) -> float {
            return logits[t] + (t == biased ? first_bias : 0.0f);
        };

        llama_token best = allowed[0];
        float best_logit = score(allowed[0]);
        for (size_t k = 1; k < allowed.size(); ++k) {
            const float l = score(allowed[k]);
            if (l > best_logit) { best_logit = l; best = allowed[k]; }
        }

        // Модель хочет закончить, и заканчивать есть чем.
        if (complete && logits[e->eos] > best_logit) break;

        std::vector<int> next;
        for (int i : alive) {
            if (pos < alt_toks[i].size() && alt_toks[i][pos] == best) next.push_back(i);
        }
        if (next.empty()) break;      // сюда попасть нельзя, но пусть
        alive.swap(next);
        ++pos;
        if (st) st->gen_tokens = (long) pos;

        // Остался один вариант и он набран целиком -- лишний проход не нужен.
        if (alive.size() == 1 && pos == alt_toks[alive[0]].size()) {
            chosen = alive[0];
            break;
        }

        llama_batch b = llama_batch_get_one(&best, 1);
        if (llama_decode(e->ctx, b) != 0) {
            LOGE("декод не прошёл на шаге %d", (int) pos);
            return -1;
        }
    }

    if (chosen < 0) {
        for (int i : alive) {
            if (alt_toks[i].size() == pos) { chosen = i; break; }
        }
    }
    if (st) st->decode_ms = ms_since(t1);
    return chosen;
}

} // namespace

extern "C" {

JNIEXPORT jlong JNICALL
Java_dev_souchastnik_engine_LlamaBridge_init(JNIEnv * env, jobject,
                                            jstring jmodel, jstring jlib_dir,
                                            jint n_threads, jboolean force_cpu,
                                            jstring j_adsp_dir) {
    // Бэкенд поднимается один раз на процесс. Сначала вариант ggml-cpu,
    // потом llama_backend_init: без загруженного CPU-бэкенда модель не
    // загрузится, и ошибка была бы невнятной ("no backends").
    const std::string lib_dir  = jstr(env, jlib_dir);
    const std::string adsp_dir = jstr(env, j_adsp_dir);

    static std::atomic<bool> backend_ready{false};
    if (!backend_ready.exchange(true)) {
        llama_log_set(llama_android_log, nullptr);
        g_cpu_backend = load_cpu_backend(lib_dir);
        llama_backend_init();
    }
    if (g_cpu_backend.empty()) {
        LOGE("движок не поднят: нет варианта ggml-cpu под этот процессор");
        return 0;
    }

    const bool want_htp = force_cpu == JNI_FALSE && ensure_hexagon(lib_dir, adsp_dir);

    Engine * e = new Engine();
    const std::string model_path = jstr(env, jmodel);

    llama_model_params mp = llama_model_default_params();
    // В этой ревизии llama.cpp use_mmap/use_mlock заменены полем load_mode:
    // модель лежит распакованной в nativeLibraryDir, mmap без mlock -- лочить
    // 500 МБ на телефоне нельзя. Q4_0 всё равно уйдёт в HTP-REPACK буферы.
    auto try_model = [&](int ngl, llama_load_mode mode) -> llama_model * {
        mp.n_gpu_layers = ngl;
        mp.load_mode    = mode;
        return llama_model_load_from_file(model_path.c_str(), mp);
    };

    if (want_htp) {
        e->model = try_model(-1, LLAMA_LOAD_MODE_MMAP);
        if (!e->model) {
            LOGI("NPU+mmap не поднялся, пробуем без mmap");
            e->model = try_model(-1, LLAMA_LOAD_MODE_NONE);
        }
    }
    if (!e->model) {
        if (want_htp) LOGI("NPU не поднялся, CPU");
        e->model = try_model(0, LLAMA_LOAD_MODE_MMAP);
    }
    if (!e->model) {
        LOGE("не удалось загрузить модель: %s", model_path.c_str());
        delete e;
        return 0;
    }
    e->vocab = llama_model_get_vocab(e->model);
    e->eos   = llama_vocab_eos(e->vocab);

    llama_context_params cp = llama_context_default_params();
    cp.n_ctx           = N_CTX;
    cp.n_batch         = N_CTX;
    cp.n_threads       = n_threads;
    cp.n_threads_batch = n_threads;
    cp.abort_callback      = abort_cb;
    cp.abort_callback_data = e;

    e->ctx = llama_init_from_model(e->model, cp);
    if (!e->ctx && mp.n_gpu_layers != 0) {
        LOGI("контекст с NPU не поднялся, CPU");
        llama_model_free(e->model);
        e->model = try_model(0, LLAMA_LOAD_MODE_MMAP);
        if (e->model) {
            e->vocab = llama_model_get_vocab(e->model);
            e->eos   = llama_vocab_eos(e->vocab);
            e->ctx   = llama_init_from_model(e->model, cp);
        }
    }
    if (!e->ctx) {
        LOGE("не удалось создать контекст");
        if (e->model) llama_model_free(e->model);
        delete e;
        return 0;
    }

    g_accel = (mp.n_gpu_layers != 0) ? first_htp_device_name() : "cpu";
    if (g_accel.empty()) g_accel = "cpu";

    LOGI("движок готов: %s+%s, n_gpu_layers %d, n_ctx %d, потоков %d, eos %d",
         g_cpu_backend.c_str(), g_accel.c_str(), (int) mp.n_gpu_layers,
         N_CTX, (int) n_threads, (int) e->eos);
    return reinterpret_cast<jlong>(e);
}

/** Имя бэкенда: вариант ggml-cpu плюс HTP0 или cpu. Пусто до init. */
JNIEXPORT jstring JNICALL
Java_dev_souchastnik_engine_LlamaBridge_backendName(JNIEnv * env, jobject) {
    if (g_cpu_backend.empty()) return env->NewStringUTF("");
    const std::string name = g_cpu_backend + "+" + g_accel;
    return env->NewStringUTF(name.c_str());
}

/**
 * @return индекс выбранного варианта в alts, -1 при ошибке или отмене.
 *   noneBias -- сдвиг порога «чисто», см. decide().
 *   jstats, если передан, заполняется как
 *   [промпт в токенах, префилл мс, декод мс, сгенерировано токенов].
 */
JNIEXPORT jint JNICALL
Java_dev_souchastnik_engine_LlamaBridge_decide(JNIEnv * env, jobject,
                                               jlong handle, jstring jsystem,
                                               jstring jtext, jobjectArray jalts,
                                               jfloat noneBias,
                                               jlongArray jstats) {
    Engine * e = reinterpret_cast<Engine *>(handle);
    if (!e || !jalts) return -1;

    const jsize n = env->GetArrayLength(jalts);
    std::vector<std::string> alts;
    alts.reserve(n);
    for (jsize i = 0; i < n; ++i) {
        jstring s = (jstring) env->GetObjectArrayElement(jalts, i);
        alts.push_back(jstr(env, s));
        env->DeleteLocalRef(s);
    }

    Stats st;
    const int idx = decide(e, jstr(env, jsystem), jstr(env, jtext), alts,
                           (float) noneBias, &st);

    if (jstats && env->GetArrayLength(jstats) >= 4) {
        jlong vals[5] = { (jlong) st.prompt_tokens, (jlong) st.prefill_ms,
                          (jlong) st.decode_ms,     (jlong) st.gen_tokens,
                          (jlong) st.cache_hit };
        const jsize nstats = env->GetArrayLength(jstats);
        env->SetLongArrayRegion(jstats, 0, nstats >= 5 ? 5 : 4, vals);
    }
    return idx;
}

JNIEXPORT void JNICALL
Java_dev_souchastnik_engine_LlamaBridge_cancel(JNIEnv *, jobject, jlong handle) {
    Engine * e = reinterpret_cast<Engine *>(handle);
    if (e) e->abort_flag.store(true, std::memory_order_relaxed);
}

JNIEXPORT void JNICALL
Java_dev_souchastnik_engine_LlamaBridge_free(JNIEnv *, jobject, jlong handle) {
    Engine * e = reinterpret_cast<Engine *>(handle);
    if (!e) return;
    e->abort_flag.store(true);
    if (e->ctx)   llama_free(e->ctx);
    if (e->model) llama_model_free(e->model);
    delete e;
}

// --- диагностика ---

JNIEXPORT jboolean JNICALL
Java_dev_souchastnik_engine_LlamaBridge_probeStateCache(JNIEnv * env, jobject,
                                                        jlong handle, jstring jpath) {
    Engine * e = reinterpret_cast<Engine *>(handle);
    if (!e) return JNI_FALSE;
    const std::string path = jstr(env, jpath);

    // Проверяем на куске, который в бою и будет общим префиксом всех
    // запросов, -- на открытии системной реплики.
    const std::vector<llama_token> probe =
        tokenize(e->vocab, TPL_SYS_OPEN, /*add_special*/ false);
    if (probe.empty()) return JNI_FALSE;

    reset_state(e);
    llama_batch b = llama_batch_get_one(const_cast<llama_token *>(probe.data()),
                                        (int32_t) probe.size());
    if (llama_decode(e->ctx, b) != 0) return JNI_FALSE;

    size_t written = llama_state_seq_save_file(e->ctx, path.c_str(), 0,
                                               probe.data(), probe.size());
    if (written == 0) {
        LOGE("state_seq_save вернул 0 -- сохранение состояния не поддержано");
        return JNI_FALSE;
    }

    reset_state(e);
    std::vector<llama_token> restored(probe.size());
    size_t n_restored = 0;
    size_t read = llama_state_seq_load_file(e->ctx, path.c_str(), 0,
                                            restored.data(), restored.size(),
                                            &n_restored);
    if (read == 0 || n_restored != probe.size()) {
        LOGE("state_seq_load не восстановил состояние (read=%d n=%d)",
             (int) read, (int) n_restored);
        return JNI_FALSE;
    }
    LOGI("prompt cache работает: %d байт, %d токенов",
         (int) written, (int) n_restored);
    return JNI_TRUE;
}

} // extern "C"
