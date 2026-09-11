package dev.souchastnik.engine

import android.app.Service
import android.content.Intent
import android.os.IBinder
import android.util.Log
import dev.souchastnik.data.Articles
import dev.souchastnik.data.Triggers
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicLong

/**
 * Живёт в процессе :engine (см. AndroidManifest). Здесь и только здесь
 * сидит модель на ~700 МБ RSS. Если Android прибьёт этот процесс по памяти,
 * клавиатура в своём процессе продолжит работать — просто строка погаснет
 * до следующего пере-бинда.
 */
class EngineService : Service() {

    companion object {
        private const val TAG = "souchastnik-engine"

        /**
         * Модель едет в APK как "нативная библиотека" и распаковывается
         * установщиком в nativeLibraryDir реальным файлом — его можно mmap-ить.
         * Классический путь через assets потребовал бы копии в filesDir,
         * то есть ещё 500 МБ на диске у пользователя.
         */
        fun modelFile(ctx: android.content.Context): File =
            File(ctx.applicationInfo.nativeLibraryDir, LlamaBridge.MODEL_LIB)

        /** Коды ответа [IEngine.load], описаны в IEngine.aidl. */
        const val LOAD_OK = 0
        const val LOAD_NO_MODEL = 1
        const val LOAD_INIT_FAILED = 2
    }

    // Один поток: генерации строго по одной. Параллелить нечего — модель
    // одна, и второй запрос всё равно ждал бы блокировки.
    private val worker = Executors.newSingleThreadExecutor()

    private var handle = 0L
    private val latestRequest = AtomicLong(0)

    private val binder = object : IEngine.Stub() {

        override fun load(): Int {
            if (handle != 0L) return LOAD_OK
            val model = modelFile(this@EngineService)
            if (!model.exists()) {
                Log.w(TAG, "модель не установлена: ${model.absolutePath}")
                return LOAD_NO_MODEL
            }
            Articles.load(this@EngineService)
            Triggers.load(this@EngineService)

            // Без dotprod (Kirin 710, Snapdragon 680...) ggml возьмёт вариант
            // armv8.0 и разбор пойдёт в разы медленнее. Работать будет.
            if (!Cpu.hasDotprod()) Log.w(TAG, "процессор без dotprod: медленный путь")

            val t0 = System.currentTimeMillis()
            val adsp = LlamaBridge.stageHtpSkels(
                applicationInfo.nativeLibraryDir, File(filesDir, "htp"))
            handle = LlamaBridge.init(
                model.absolutePath, applicationInfo.nativeLibraryDir, Cpu.threadCount(),
                forceCpu = false, adspDir = adsp)
            Log.i(TAG, "load: handle=$handle, backend=${LlamaBridge.backendName()} " +
                "за ${System.currentTimeMillis() - t0} мс")
            return if (handle != 0L) LOAD_OK else LOAD_INIT_FAILED
        }

        override fun unload() {
            val h = handle
            handle = 0L
            if (h != 0L) worker.execute { LlamaBridge.free(h) }
        }

        override fun isLoaded(): Boolean = handle != 0L

        override fun analyze(text: String?, requestId: Long, cb: IEngineCallback?) {
            if (text == null || cb == null) return
            latestRequest.set(requestId)

            // Человек нажал следующую клавишу — предыдущая генерация не нужна.
            // abort-колбэк в нативной части вернёт true и llama_decode выйдет.
            if (handle != 0L) LlamaBridge.cancel(handle)

            worker.execute {
                if (latestRequest.get() != requestId) return@execute  // устарел, пока ждал очереди
                val h = handle
                if (h == 0L) {
                    safe { cb.onError(requestId, "not_loaded") }
                    return@execute
                }
                // Словарь триггеров -- ДО модели. Молчат триггеры -- значит
                // в тексте нет ни одного слова, за которое хоть что-то
                // прилетает, и полгига модели крутить незачем.
                val hit = Triggers.match(text)
                if (hit.codes.isEmpty()) {
                    safe { cb.onVerdict(requestId, Articles.NONE, 0) }
                    return@execute
                }

                val t0 = System.currentTimeMillis()

                // Судья: в промпте таблица кандидатов и примеры, в ответе код
                // статьи целиком либо "none". Калитки «есть состав?» перед ним
                // больше нет: на 66 контрольных фразах она стоила ~500 токенов
                // префилла (больше половины всего времени разбора) и меняла
                // итог на две фразы в одну сторону и две в другую.
                val alts = (listOf(Articles.NONE) + hit.codes).toTypedArray()
                val index = try {
                    val system = Articles.judgeSystem(hit.codes, hit.clean)
                    LlamaBridge.decide(h, system, text, alts, LlamaBridge.NONE_BIAS, null)
                } catch (t: Throwable) {
                    Log.e(TAG, "разбор упал", t)
                    LlamaBridge.ERROR
                }
                val ms = System.currentTimeMillis() - t0

                if (latestRequest.get() != requestId) return@execute  // успел устареть, пока считали
                if (index == LlamaBridge.ERROR) {
                    safe { cb.onError(requestId, "aborted") }
                } else {
                    // За Binder едет уже готовый код статьи, а не индекс:
                    // справочник загружен в этом же процессе.
                    safe { cb.onVerdict(requestId, alts[index], ms) }
                }
            }
        }

        override fun cancel() {
            latestRequest.incrementAndGet()
            if (handle != 0L) LlamaBridge.cancel(handle)
        }
    }

    override fun onBind(intent: Intent?): IBinder = binder

    override fun onDestroy() {
        binder.unload()
        worker.shutdown()
        super.onDestroy()
    }

    /** Клиент мог умереть, пока мы считали: DeadObjectException — норма, не ошибка. */
    private inline fun safe(block: () -> Unit) {
        try {
            block()
        } catch (_: android.os.RemoteException) {
        }
    }
}
