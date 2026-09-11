# Почему модель лежит здесь и называется `.so`

В этой папке должен лежать файл

    arm64-v8a/libmodel-qwen35-08b-q40.so

Это не библиотека. Это GGUF-файл модели, переименованный. Квант — Q4_0,
не Q4_K_M: на ARM с dotprod у Q4_0 есть «repack»-ядра, префилл быстрее в
1,3–1,9 раза при том же качестве (замер в `docs/DESIGN.md`). Квантовать
надо из f16 напрямую: переквантованный из Q4_K_M файл теряет точность
вдвое. Имя файла задано в `LlamaBridge.MODEL_LIB`.

## Зачем так

У приложения нет разрешения `INTERNET` — значит, модель нельзя докачать
после установки, она обязана ехать внутри APK. Дальше выбор из трёх:

| Вариант | Проблема |
|---|---|
| `assets/` | Android не даёт файловый путь внутрь APK. Для `mmap` нужен реальный файл, то есть копия в `filesDir` — **ещё 500 МБ** на диске пользователя. |
| Докачивание при первом запуске | Требует `INTERNET`, то есть ломает всю позицию приложения по приватности. Не рассматривается. |
| `jniLibs/` + `useLegacyPackaging = true` | Установщик распаковывает файл в `nativeLibraryDir` — реальный путь, `mmap` работает, копии нет. |

Отсюда третий вариант и странное имя файла. Путь получаем как
`applicationInfo.nativeLibraryDir` (см. `EngineService.modelFile`).

Существенно: `useLegacyPackaging = true` в `app/build.gradle.kts` — не
рудимент, а условие работоспособности. При `false` библиотеки читаются
страницами прямо из APK и файла на диске не существует.

## Соседи по каталогу: варианты ядер ggml

Рядом с моделью в `nativeLibraryDir` окажутся семь файлов
`libggml-cpu-android_<arch>.so` — от `armv8.0_1` (без dotprod, для
Cortex-A53/A73) до `armv9.2_2` (i8mm, SVE, SME). Они НЕ лежат в этой папке:
их собирает CMake (`GGML_CPU_ALL_VARIANTS` в `build.gradle.kts`), а мост при
`init` выбирает подходящий процессору по `ggml_backend_score()` и грузит
через `ggml_backend_load` (`load_cpu_backend()` в `llama_bridge.cpp`). Имя
файла — контракт: префикс `libggml-cpu-` и суффикс `.so`.

Если сборка с Hexagon SDK, сюда же попадут `libggml-hexagon.so` и DSP-skel
`libggml-htp-v*.so`. Skel — не ARM, `llvm-strip` их портит; AGP не должен
их страйпать (`keepDebugSymbols` в `build.gradle.kts`). Перед запуском мост
копирует skel в `filesDir/htp` с режимом 0644: CDSP иначе часто не читает
`nativeLibraryDir`. Подробности — в `CHANGELOG.md`.

## Откуда взять файл

Для спайка (замер скорости, обучение не нужно):

```bash
huggingface-cli download unsloth/Qwen3.5-0.8B-GGUF \
    Qwen3.5-0.8B-Q4_0.gguf --local-dir build/
cp build/Qwen3.5-0.8B-Q4_0.gguf \
   app/src/main/jniLibs/arm64-v8a/libmodel-qwen35-08b-q40.so
```

Для релиза — своя дообученная, через `bash tools/make_gguf.sh`.

## В git не коммитим

Полгигабайта весов в репозитории не нужны никому. `.gitignore` их исключает,
релизный APK собирается на машине, где файл положен руками, и публикуется
в GitHub Releases (лимит 2 ГБ на файл — влезаем).

Без этого файла приложение собирается и запускается: клавиатура работает,
строка показывает «модель не установлена».
