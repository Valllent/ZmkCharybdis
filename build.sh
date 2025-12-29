
#!/bin/bash
set -e

BUILD_MATRIX_PATH="build.yaml"
CONFIG_PATH="config"
KEYMAP_PATH="boards/shields/charybdis/keymaps"
FALLBACK_BINARY="bin"
PROJECT_ROOT_DIR=$(pwd)
FIRMWARE_OUTPUT_DIR="${PROJECT_ROOT_DIR}/.output"
BUILD_WORK_DIR="${PROJECT_ROOT_DIR}/.build"  # Рабочая директория внутри проекта

echo "SCRIPT: Установка зависимостей..."
python3 -m pip install remarshal

echo "SCRIPT: Конвертация основной раскладки..."
python3 scripts/convert_keymap.py -c q2c --in-path "${PROJECT_ROOT_DIR}/config/charybdis.keymap"

echo "SCRIPT: Подготовка keymap файлов..."
mkdir -p "${PROJECT_ROOT_DIR}/${KEYMAP_PATH}/"

# Копируем keymaps ОДИН РАЗ до цикла
if [ -f "${PROJECT_ROOT_DIR}/config/charybdis.keymap" ]; then
    cp "${PROJECT_ROOT_DIR}/config/charybdis.keymap" "${PROJECT_ROOT_DIR}/${KEYMAP_PATH}/qwerty.keymap"
    echo "SCRIPT: Скопирован qwerty.keymap"
fi
if [ -f "${PROJECT_ROOT_DIR}/config/colemak_dh.keymap" ]; then
    cp "${PROJECT_ROOT_DIR}/config/colemak_dh.keymap" "${PROJECT_ROOT_DIR}/${KEYMAP_PATH}/colemak_dh.keymap"
    echo "SCRIPT: Скопирован colemak_dh.keymap"
fi

echo "SCRIPT: Чтение матрицы сборки из ${BUILD_MATRIX_PATH}..."
BUILD_MATRIX=$(remarshal -i "${BUILD_MATRIX_PATH}" -t json | jq -c '.')

if [ -z "$BUILD_MATRIX" ]; then
    echo "SCRIPT: Не удалось прочитать матрицу сборки."
    exit 1
fi

rm -rf "${FIRMWARE_OUTPUT_DIR}"
mkdir -p "${FIRMWARE_OUTPUT_DIR}"

# Очищаем и создаём рабочую директорию
rm -rf "${BUILD_WORK_DIR}"
mkdir -p "${BUILD_WORK_DIR}"

BUILD_INDEX=0

echo "$BUILD_MATRIX" | jq -c '.include[]' | while read -r item; do
    BOARD=$(echo "$item" | jq -r '.board')
    SHIELD=$(echo "$item" | jq -r '.shield')
    KEYMAP=$(echo "$item" | jq -r '.keymap')
    FORMAT=$(echo "$item" | jq -r '.format')
    ARTIFACT_NAME=$(echo "$item" | jq -r '."artifact-name"')
    SNIPPET=$(echo "$item" | jq -r '.snippet')
    CMAKE_ARGS=$(echo "$item" | jq -r '."cmake-args"')

    echo "----------------------------------------------------"
    echo "SCRIPT: Начало сборки для: Shield='${SHIELD}', Board='${BOARD}', Keymap='${KEYMAP}', Format='${FORMAT}'"
    echo "----------------------------------------------------"

    # Формируем extra_west_args
    EXTRA_WEST_ARGS=""
    if [ -n "${SNIPPET}" ] && [ "${SNIPPET}" != "null" ]; then
        EXTRA_WEST_ARGS="-S ${SNIPPET}"
    fi

    # Формируем extra_cmake_args
    EXTRA_CMAKE_ARGS=""
    if [ -n "${SHIELD}" ] && [ "${SHIELD}" != "null" ]; then
        EXTRA_CMAKE_ARGS="-DSHIELD=${SHIELD}"
    fi

    # CMAKE_ARGS может быть null (исправлен синтаксис)
    if [ "${CMAKE_ARGS}" = "null" ]; then
        CMAKE_ARGS=""
    fi

    # Создаём изолированную копию проекта внутри рабочей директории
    ISOLATED_PROJECT_DIR="${BUILD_WORK_DIR}/build_${BUILD_INDEX}"
    BUILD_INDEX=$((BUILD_INDEX + 1))

    echo "SCRIPT: Создаётся изолированная директория: ${ISOLATED_PROJECT_DIR}"
    mkdir -p "${ISOLATED_PROJECT_DIR}"

    # Копируем только нужные файлы (без .git и служебных директорий)
    rsync -a \
        --exclude='.git' \
        --exclude='.output' \
        --exclude='.build' \
        "${PROJECT_ROOT_DIR}/" "${ISOLATED_PROJECT_DIR}/"

    docker run --rm \
        -v "${PROJECT_ROOT_DIR}:${PROJECT_ROOT_DIR}" \
        -w "${ISOLATED_PROJECT_DIR}" \
        -e "SHIELD=${SHIELD}" \
        -e "BOARD=${BOARD}" \
        -e "KEYMAP=${KEYMAP}" \
        -e "FORMAT=${FORMAT}" \
        -e "ARTIFACT_NAME=${ARTIFACT_NAME}" \
        -e "EXTRA_WEST_ARGS=${EXTRA_WEST_ARGS}" \
        -e "EXTRA_CMAKE_ARGS=${EXTRA_CMAKE_ARGS}" \
        -e "CMAKE_ARGS=${CMAKE_ARGS}" \
        -e "CONFIG_PATH=${CONFIG_PATH}" \
        -e "KEYMAP_PATH=${KEYMAP_PATH}" \
        -e "FALLBACK_BINARY=${FALLBACK_BINARY}" \
        -e "FIRMWARE_OUTPUT_DIR=${FIRMWARE_OUTPUT_DIR}" \
        -e "ISOLATED_PROJECT_DIR=${ISOLATED_PROJECT_DIR}" \
        zmkfirmware/zmk-build-arm:stable /bin/bash -c '
        set -ex

        BUILD_DIR=$(mktemp -d)

        if [ -e zephyr/module.yml ]; then
            ZMK_LOAD_ARG="-DZMK_EXTRA_MODULES=${ISOLATED_PROJECT_DIR}"
            NEW_TMP_DIR=${TMPDIR:-/tmp}/zmk-config
            mkdir -p "${NEW_TMP_DIR}"
            BASE_DIR=${NEW_TMP_DIR}
        else
            BASE_DIR=${ISOLATED_PROJECT_DIR}
        fi

        # Добавляем ZMK_LOAD_ARG к EXTRA_CMAKE_ARGS
        if [ -n "${ZMK_LOAD_ARG}" ]; then
            EXTRA_CMAKE_ARGS="${EXTRA_CMAKE_ARGS} ${ZMK_LOAD_ARG}"
        fi

        FINAL_ARTIFACT_NAME="${ARTIFACT_NAME:-${SHIELD:+${SHIELD}-}${BOARD}-zmk}"

        if [ "${BASE_DIR}" != "${ISOLATED_PROJECT_DIR}" ]; then
            BASE_CONFIG_PATH="${BASE_DIR}/${CONFIG_PATH}"
            mkdir -p "$BASE_CONFIG_PATH"
            cp -R "${ISOLATED_PROJECT_DIR}/${CONFIG_PATH}"/* "$BASE_CONFIG_PATH/"

            if [ "${SHIELD}" != "settings_reset" ] && [ "${SHIELD}" != "null" ]; then
                # Перемещаем layouts.dtsi в директорию shield
                if [ -f "$BASE_CONFIG_PATH/charybdis-layouts.dtsi" ]; then
                    mv -v "$BASE_CONFIG_PATH/charybdis-layouts.dtsi" \
                        "${ISOLATED_PROJECT_DIR}/boards/shields/charybdis-${FORMAT}/"
                fi

                # Копируем активный keymap
                cp -Rv "${ISOLATED_PROJECT_DIR}/${KEYMAP_PATH}/${KEYMAP}.keymap" \
                    "$BASE_CONFIG_PATH/charybdis.keymap"

                case "${FORMAT}" in
                    *bt*)
                        sed -i "s/device = <&vtrackball>;/device = <\&trackball>;/g" "$BASE_CONFIG_PATH/charybdis.keymap"
                        ;;
                esac
            fi
        fi

        # Удаляем лишние shields
        find "${ISOLATED_PROJECT_DIR}/boards/shields" \
            -mindepth 1 \
            -maxdepth 1 \
            ! -name "charybdis-${FORMAT}" \
            -exec rm -rf {} +

        cd "${BASE_DIR}"
        west init -l "${BASE_DIR}/${CONFIG_PATH}"
        west update
        west zephyr-export

        echo "Running: west build --pristine -s zmk/app -d ${BUILD_DIR} -b ${BOARD} ${EXTRA_WEST_ARGS} -- -DZMK_CONFIG=${BASE_DIR}/${CONFIG_PATH} ${EXTRA_CMAKE_ARGS} ${CMAKE_ARGS}"

        west build --pristine -s zmk/app -d "${BUILD_DIR}" -b "${BOARD}" ${EXTRA_WEST_ARGS} -- -DZMK_CONFIG="${BASE_DIR}/${CONFIG_PATH}" ${EXTRA_CMAKE_ARGS} ${CMAKE_ARGS}

        mkdir -p "${BUILD_DIR}/artifacts"
        if [ -f "${BUILD_DIR}/zephyr/zmk.uf2" ]; then
            cp "${BUILD_DIR}/zephyr/zmk.uf2" "${BUILD_DIR}/artifacts/${FINAL_ARTIFACT_NAME}.uf2"
        elif [ -f "${BUILD_DIR}/zephyr/zmk.${FALLBACK_BINARY}" ]; then
            cp "${BUILD_DIR}/zephyr/zmk.${FALLBACK_BINARY}" "${BUILD_DIR}/artifacts/${FINAL_ARTIFACT_NAME}.${FALLBACK_BINARY}"
        fi

        cp ${BUILD_DIR}/artifacts/* "${FIRMWARE_OUTPUT_DIR}/"
    '

    echo "SCRIPT: Сборка ${SHIELD} завершена"

done

# Очищаем рабочую директорию после всех сборок
rm -rf "${BUILD_WORK_DIR}"

echo "----------------------------------------------------"
echo "Сборка завершена!"
echo "Готовые файлы прошивки находятся в директории: ${FIRMWARE_OUTPUT_DIR}"
echo "----------------------------------------------------"