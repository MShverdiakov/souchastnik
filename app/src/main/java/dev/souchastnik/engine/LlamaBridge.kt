package dev.souchastnik.engine

import android.system.Os
import android.system.OsConstants
import android.util.Log
import java.io.File

/**
 * Тонкая обёртка над llama.cpp. Живёт только в процессе :engine.
 *
 * Модель выбирает ОДИН вариант из закрытого списка строк: коды
 * статей-кандидатов плюс "none". Ни сэмплера, ни
 * GBNF-грамматики в проекте нет: при закрытом списке достаточно на каждом
 * шаге брать argmax по тем токенам, которыми продолжается хотя бы один ещё
 * живой вариант. Грамматический сэмплер вместо этого обходил бы весь
 * словарь на 248 320 токенов и стоил сотни миллисекунд на токен.
 * Подробности в llama_bridge.cpp.
 */
object LlamaBridge {

    init {
        System.loadLibrary("souchastnik")
    }

    /**
     * Имя файла модели внутри nativeLibraryDir. См. jniLibs/README.md.
     *
     * Q4_0, а не Q4_K_M: на ARM с dotprod у Q4_0 есть «repack»-ядра
     * (GGML_USE_CPU_REPACK), у K-квантов нет. Префилл быстрее в 1,3 раза на
     * телефоне и в 1,9 на x86 при том же качестве на контрольном наборе
     * (с NONE_BIAS = 1.0). Файл обязан быть квантован из f16 напрямую:
     * переквантование Q4_K_M -> Q4_0 роняет точность с 29/35 до 18/35.
     */
    const val MODEL_LIB = "libmodel-qwen35-08b-q40.so"

    /** Ошибка или отмена: такой индекс варианта не существует. */
    const val ERROR = -1

    /**
     * Сдвиг порога «чисто»: прибавляется к логиту "none" перед argmax.
     * Ноль — честный argmax. Замер на 66 контрольных фразах
     * (tools/bench_variants.py judge_lite, порог none), модель Q4_0:
     *
     *     сдвиг   с составом   чистых верно
     *      0.0      25/35        23/31
     *      0.5      24/35        24/31
     *      1.0      22/35        27/31
     *      1.5      20/35        28/31
     *
     * Пропущенная статья для шутки безвредна, ложная на «кошка на стол
     * залезла» выглядит как поломка, поэтому 1.0. Квант влияет на баланс:
     * Q4_K_M на том же промпте уже при нуле давал 22/35 и 28/31. При смене
     * файла модели таблицу снимать заново.
     */
    const val NONE_BIAS = 1.0f

    /**
     * @param libDir `applicationInfo.nativeLibraryDir`: здесь лежат варианты
     *   ядер `libggml-cpu-android_*.so`, из которых мост выберет подходящий
     *   процессору (см. `load_cpu_backend` в llama_bridge.cpp), и
     *   `libggml-hexagon.so`.
     * @param forceCpu не грузить HTP, все слои на CPU. Для A/B в BenchActivity.
     * @param adspDir каталог с копиями `libggml-htp-v*.so` (обычно filesDir/htp):
     *   CDSP часто не читает nativeLibraryDir из‑за SELinux.
     * @return хендл движка, 0 — ошибка (в т. ч. ни один вариант не подошёл)
     */
    external fun init(
        modelPath: String,
        libDir: String,
        nThreads: Int,
        forceCpu: Boolean = false,
        adspDir: String = "",
    ): Long

    /**
     * Имя бэкенда: вариант ядер плюс куда уехали слои, например
     * `android_armv8.6_1+HTP0` или `android_armv8.6_1+cpu`. Пусто до init.
     */
    external fun backendName(): String

    /**
     * Разбирает одно сообщение и выбирает вариант из [alts].
     *
     * Промпт собирается по чат-шаблону Qwen3.5 с ЗАКРЫТЫМ блоком
     * рассуждения. Сырой промпт этой модели давать нельзя: без шаблона
     * ответы схлопываются в один вариант на все входы.
     *
     * @param system системное сообщение — [dev.souchastnik.data.Articles.judgeSystem].
     * @param alts закрытый список ответов; порядок задаёт возвращаемый индекс,
     *   alts[0] — "none".
     * @param noneBias сдвиг порога «чисто», обычно [NONE_BIAS].
     * @param stats если передан массив длиной не меньше 4, заполняется как
     *   [промпт в токенах, префилл мс, декод мс, сгенерировано токенов];
     *   пятый элемент, если есть — 1 при попадании в кэш системного префикса.
     * @return индекс выбранного варианта в [alts], либо [ERROR]
     */
    external fun decide(
        handle: Long,
        system: String,
        text: String,
        alts: Array<String>,
        noneBias: Float,
        stats: LongArray?,
    ): Int

    external fun cancel(handle: Long)

    external fun free(handle: Long)

    // --- спайк ---

    /**
     * Пытается сохранить состояние после общего префикса промпта и
     * восстановить его. У Qwen3.5 18 из 24 слоёв — Gated DeltaNet с
     * рекуррентным состоянием, а не KV-кэш, и seq-state save/restore для
     * гибридных архитектур в llama.cpp работает хуже, чем для чистых
     * трансформеров. Если здесь false — полный префилл на каждый запрос.
     */
    external fun probeStateCache(handle: Long, path: String): Boolean

    /**
     * Копирует HTP-skel в [destDir] с режимом 0644: CDSP читает файл из
     * другого процесса и часто не видит `/data/app/.../lib/arm64`.
     * @return абсолютный путь [destDir]
     */
    fun stageHtpSkels(libDir: String, destDir: File): String {
        destDir.mkdirs()
        val srcDir = File(libDir)
        val skels = srcDir.listFiles()
            ?.filter { it.name.startsWith("libggml-htp-") && it.name.endsWith(".so") }
            .orEmpty()
        if (skels.isEmpty()) {
            Log.w(TAG, "HTP-skel не найдены в $libDir")
            return destDir.absolutePath
        }
        val mode = OsConstants.S_IRUSR or OsConstants.S_IWUSR or
            OsConstants.S_IRGRP or OsConstants.S_IROTH
        for (src in skels) {
            val dst = File(destDir, src.name)
            if (!dst.exists() || dst.length() != src.length() ||
                dst.lastModified() < src.lastModified()
            ) {
                src.copyTo(dst, overwrite = true)
            }
            try {
                Os.chmod(dst.absolutePath, mode)
            } catch (e: Exception) {
                Log.w(TAG, "chmod ${dst.name}: ${e.message}")
                dst.setReadable(true, false)
            }
        }
        Log.i(TAG, "HTP-skel: ${skels.size} шт. в ${destDir.absolutePath}")
        return destDir.absolutePath
    }

    private const val TAG = "souchastnik-native"
}
