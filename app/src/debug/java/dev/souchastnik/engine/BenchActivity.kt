package dev.souchastnik.engine

import android.app.Activity
import android.graphics.Color
import android.graphics.Typeface
import android.os.Bundle
import android.widget.ScrollView
import android.widget.TextView
import dev.souchastnik.data.Articles
import dev.souchastnik.data.Triggers

/**
 * Спайк на устройстве. Запускается напрямую:
 *
 *   adb shell am start -n dev.souchastnik/.engine.BenchActivity
 *   adb shell am start -n dev.souchastnik/.engine.BenchActivity --ez cpu true
 *   adb logcat -s souchastnik-bench:I souchastnik-native:I ggml-hex:I
 *
 * Гоняет ровно тот конвейер, что и tools/bench_variants.py judge:
 * словарь триггеров сужает справочник, судья выбирает код статьи из
 * кандидатов либо none. Фразы и ожидания те же, что в try.py, чтобы
 * телефон и десктоп можно было класть рядом.
 *
 * Примеры фраз берутся из assets/examples.json (копия
 * tools/examples.local.json, в гит не идёт). Строка «примеры в промпте»
 * в шапке говорит, попал ли файл в сборку: без него модель осторожничает
 * и уходит в none почти на всём.
 *
 * Работает в процессе по умолчанию, а не в :engine — здесь нужен прямой
 * доступ к LlamaBridge без Binder-накладных.
 */
class BenchActivity : Activity() {

    companion object {
        private const val TAG = "souchastnik-bench"

        /** Фраза и то, чего от неё ждём. Тот же список, что в tools/try.py. */
        private val CASES = listOf(
            "ты совсем дурак что ли" to "5.61",
            "если ты еще раз так сделаешь я тебя закопаю" to "119",
            "скинь мне фильм который в кино идет" to "146",
            "давай я тебе налом отдам а ты счет не выставляй" to "198/171",
            "я вчера сел за руль после трех бутылок пива и доехал нормально" to "12.8",
            "он мне денег не отдает, пойду вынесу у него из машины магнитолу" to "158",
            "да наша армия там вообще ничего не добилась, позор" to "20.3.3",
            "во сколько встречаемся завтра у метро" to "чисто",
            "купи молока и хлеба пожалуйста" to "чисто",
            "поздравляю с днем рождения, здоровья тебе" to "чисто",
            "я в церкви был, у них там купола такие красивые" to "чисто",
        )
    }

    private val out = StringBuilder()
    private lateinit var view: TextView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Articles.load(this)
        Triggers.load(this)

        view = TextView(this).apply {
            typeface = Typeface.MONOSPACE
            textSize = 11f
            setBackgroundColor(Color.parseColor("#101012"))
            setTextColor(Color.parseColor("#E8E8E8"))
            val p = (12 * resources.displayMetrics.density).toInt()
            setPadding(p, p, p, p)
        }
        setContentView(ScrollView(this).apply { addView(view) })

        Thread { run() }.start()
    }

    private fun run() {
        // Другой файл модели для сравнения квантов и архитектур без пересборки:
        //   adb push x.gguf /data/local/tmp/ && adb shell chmod 644 /data/local/tmp/x.gguf
        //   adb shell am start -n dev.souchastnik/.engine.BenchActivity --es model /data/local/tmp/x.gguf
        val model = intent?.getStringExtra("model")?.let { java.io.File(it) }
            ?: EngineService.modelFile(this)
        log("модель: ${model.absolutePath}")
        if (!model.exists()) {
            log("НЕТ ФАЙЛА МОДЕЛИ — см. app/src/main/jniLibs/README.md")
            return
        }
        log("размер: ${model.length() / 1024 / 1024} МБ")
        log("статей: ${Articles.size()}, групп триггеров: ${Triggers.size()}")
        log("примеры в промпте: ${if (dev.souchastnik.data.Examples.isEmpty()) "НЕТ" else "есть"}")

        log("cpu features: ${Cpu.features()?.sorted()?.joinToString(" ") ?: "/proc/cpuinfo недоступен"}")
        if (!Cpu.hasDotprod()) log("без dotprod: ggml возьмёт вариант armv8.0, будет медленно")

        // Число потоков можно задать снаружи, чтобы сравнивать без пересборки:
        //   adb shell am start -n dev.souchastnik/.engine.BenchActivity --ei threads 2
        // По умолчанию — тот же выбор, что у движка в бою (Cpu.threadCount).
        val threads = intent?.getIntExtra("threads", 0)?.takeIf { it > 0 } ?: Cpu.threadCount()
        log("потоков: $threads")

        val forceCpu = intent?.getBooleanExtra("cpu", false) == true
        if (forceCpu) log("форс CPU (--ez cpu true)")

        // Пауза между фразами в секундах — имитация набора с перерывами на
        // телефонах с 3–4 ГБ RAM: вытесняет ли система страницы mmap модели,
        // пока человек думает (тогда фраза после паузы заметно дольше):
        //   adb shell am start -n dev.souchastnik/.engine.BenchActivity --ei pause 30
        val pauseSec = intent?.getIntExtra("pause", 0) ?: 0
        if (pauseSec > 0) log("пауза между фразами: $pauseSec с")

        val t0 = System.currentTimeMillis()
        val adsp = LlamaBridge.stageHtpSkels(
            applicationInfo.nativeLibraryDir, java.io.File(filesDir, "htp"))
        val h = LlamaBridge.init(
            model.absolutePath, applicationInfo.nativeLibraryDir, threads,
            forceCpu = forceCpu, adspDir = adsp)
        if (h == 0L) {
            log("init ПРОВАЛИЛСЯ — смотри logcat souchastnik-native")
            return
        }
        log("загрузка: ${System.currentTimeMillis() - t0} мс, backend: ${LlamaBridge.backendName()}")

        val cacheOk = LlamaBridge.probeStateCache(h, "${cacheDir.absolutePath}/state.bin")
        log("prompt cache: ${if (cacheOk) "РАБОТАЕТ" else "НЕ РАБОТАЕТ"}")
        log("")

        // Прогрев: первый проход всегда медленнее, страницы модели ещё не
        // подтянуты из mmap. Включать его в статистику нечестно.
        Triggers.match(CASES[0].first).let { w ->
            val alts = (listOf(Articles.NONE) + w.codes).toTypedArray()
            LlamaBridge.decide(h, Articles.judgeSystem(w.codes, w.clean), CASES[0].first, alts,
                               LlamaBridge.NONE_BIAS, null)
        }

        log("%-46s %-8s %-8s %s".format("фраза", "ждём", "вердикт", "мс кэш (промпт/декод)"))
        val totals = ArrayList<Long>()
        var hits = 0

        // Одна произвольная фраза вместо набора — чтобы воспроизвести то, что
        // человек видел в строке, ровно тем же путём (триггеры, промпт, сдвиг):
        //   adb shell am start -n dev.souchastnik/.engine.BenchActivity --es phrase "текст"
        val cases = intent?.getStringExtra("phrase")?.let { listOf(it to "?") } ?: CASES

        for ((text, want) in cases) {
            if (pauseSec > 0) Thread.sleep(pauseSec * 1000L)
            val stats = LongArray(5)
            var promptTokens = 0L
            var ms = 0L
            var verdict: String

            val hit = Triggers.match(text)
            if (hit.codes.isEmpty()) {
                verdict = "чисто"                      // триггеры молчат, модель не крутим
            } else {
                val alts = (listOf(Articles.NONE) + hit.codes).toTypedArray()
                val system = Articles.judgeSystem(hit.codes, hit.clean)
                val i = LlamaBridge.decide(h, system, text, alts, LlamaBridge.NONE_BIAS, stats)
                promptTokens += stats[0]
                ms += stats[1] + stats[2]
                verdict = when {
                    i == LlamaBridge.ERROR    -> "ОШИБКА"
                    alts[i] == Articles.NONE  -> "чисто"
                    else                      -> alts[i]
                }
            }

            if (verdict == want || (want.contains('/') && want.split('/').contains(verdict))) hits++
            if (ms > 0) totals += ms
            val cache = when {
                ms == 0L -> "—"
                stats[4] == 1L -> "HIT"
                else -> "miss"
            }
            log("%-46s %-8s %-8s %5dм %s (%d т)".format(
                text.take(44), want, verdict, ms, cache, promptTokens))
        }

        log("")
        log("совпало с ожиданием: $hits из ${cases.size}")
        if (totals.isNotEmpty()) {
            totals.sort()
            log("медиана: ${totals[totals.size / 2]} мс, максимум: ${totals.last()} мс")
            log("(медиана только по фразам, где модель реально крутилась)")
        }

        // Имитация набора: системка судьи та же, растёт только user-текст.
        // Это то, что человек чувствует между клавишами, а не набор разных статей.
        log("")
        log("набор одной фразы (кэш системки):")
        val typing = listOf(
            "ты совсем дурак",
            "ты совсем дурак что",
            "ты совсем дурак что ли",
        )
        for (text in typing) {
            val hit = Triggers.match(text)
            if (hit.codes.isEmpty()) {
                log("%-46s (триггеры молчат)".format(text.take(44)))
                continue
            }
            val stats = LongArray(5)
            val alts = (listOf(Articles.NONE) + hit.codes).toTypedArray()
            val system = Articles.judgeSystem(hit.codes, hit.clean)
            LlamaBridge.decide(h, system, text, alts, LlamaBridge.NONE_BIAS, stats)
            val ms = stats[1] + stats[2]
            log("%-46s %5dм %s (head+rest %d т, префилл %dм декод %dм)".format(
                text.take(44), ms,
                if (stats[4] == 1L) "HIT" else "miss",
                stats[0], stats[1], stats[2]))
        }

        LlamaBridge.free(h)
    }

    private fun log(s: String) {
        android.util.Log.i(TAG, s)
        out.append(s).append('\n')
        runOnUiThread { view.text = out.toString() }
    }
}
