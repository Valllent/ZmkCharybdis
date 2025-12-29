#!/bin/bash
set -e

BUILD_MATRIX_PATH="build.yaml"
CONFIG_PATH="config"
KEYMAP_PATH="boards/shields/charybdis/keymaps"
FALLBACK_BINARY="bin"
PROJECT_ROOT_DIR=$(pwd)
FIRMWARE_OUTPUT_DIR="${PROJECT_ROOT_DIR}/firmware_output"

echo "SCRIPT: Установка зависимостей..."
python3 -m pip install remarshal

echo "SCRIPT: Конвертация основной раскладки..."
python3 scripts/convert_keymap.py -c q2c --in-path "${PROJECT_ROOT_DIR}/config/charybdis.keymap"

echo "SCRIPT: Чтение матрицы сборки из ${BUILD_MATRIX_PATH}..."
BUILD_MATRIX=$(remarshal -i "${BUILD_MATRIX_PATH}" -t json | jq -c '.')

if [ -z "$BUILD_MATRIX" ]; then
    echo "SCRIPT: Не удалось прочитать матрицу сборки."
    exit 1
fi

rm -rf "${FIRMWARE_OUTPUT_DIR}"
mkdir -p "${FIRMWARE_OUTPUT_DIR}"

echo "$BUILD_MATRIX" | jq -c '.include[]' | while read -r item; do
    BOARD=$(echo "$item" | jq -r '.board')
    SHIELD=$(echo "$item" | jq -r '.shield')
    KEYMAP=$(echo "$item" | jq -r '.keymap')
    FORMAT=$(echo "$item" | jq -r '.format')
    ARTIFACT_NAME=$(echo "$item" | jq -r '."artifact-name"')
    SNIPPET=$(echo "$item" | jq -r '.snippet')
    CMAKE_ARGS=$(echo "$item" | jq -r '."cmake-args"')

    echo "----------------------------------------------------"
    echo "SCRIPT: Начало сборки для: Shield='${SHIELD}', Board='${BOARD}', Keymap='${KEYMAP}'"
    echo "----------------------------------------------------"

    # Формируем extra_west_args
    EXTRA_WEST_ARGS=""
    if [ -n "${SNIPPET}" ] && [ "${SNIPPET}" != "null" ]; then
        EXTRA_WEST_ARGS="-S ${SNIPPET}"
    fi

    # Формируем extra_cmake_args (ключевое исправление!)
    EXTRA_CMAKE_ARGS=""
    if [ -n "${SHIELD}" ] && [ "${SHIELD}" != "null" ]; then
        EXTRA_CMAKE_ARGS="-DSHIELD=${SHIELD}"
    fi

    # CMAKE_ARGS может быть null
    if [ "${CMAKE_ARGS}" == "null" ]; then
        CMAKE_ARGS=""
    fi

    docker run --rm \
        -v "${PROJECT_ROOT_DIR}:${PROJECT_ROOT_DIR}" -w "${PROJECT_ROOT_DIR}" \
        -e "SHIELD=${SHIELD}" \
        -e "BOARD=${BOARD}" \
        -e "KEYMAP=${KEYMAP}" \
        -e "FORMAT=${FORMAT}" \
        -e "ARTIFACT_NAME=${ARTIFACT_NAME}" \
        -e "EXTRA_WEST_ARGS=${EXTRA_WEST_ARGS}" \
        -e "EXTRA_CMAKE_ARGS=${EXTRA_CMAKE_ARGS}" \
        -e "CMAKE_ARGS=${CMAKE_ARGS}" \
        zmkfirmware/zmk-build-arm:stable /bin/bash -c '
        set -ex

        BUILD_DIR=$(mktemp -d)

        if [ -e zephyr/module.yml ]; then
            ZMK_LOAD_ARG="-DZMK_EXTRA_MODULES='"${PROJECT_ROOT_DIR}"'"
            NEW_TMP_DIR=${TMPDIR:-/tmp}/zmk-config
            mkdir -p "${NEW_TMP_DIR}"
            BASE_DIR=${NEW_TMP_DIR}
        else
            BASE_DIR='"${PROJECT_ROOT_DIR}"'
        fi

        # Добавляем ZMK_LOAD_ARG к EXTRA_CMAKE_ARGS
        if [ -n "${ZMK_LOAD_ARG}" ]; then
            EXTRA_CMAKE_ARGS="${EXTRA_CMAKE_ARGS} ${ZMK_LOAD_ARG}"
        fi

        DISPLAY_NAME="${SHIELD:+${SHIELD} - }${BOARD}"
        FINAL_ARTIFACT_NAME="${ARTIFACT_NAME:-${SHIELD:+${SHIELD}-}${BOARD}-zmk}"

        mkdir -p "'"${PROJECT_ROOT_DIR}/${KEYMAP_PATH}"'/"
        cd "'"${PROJECT_ROOT_DIR}"'"

        # Перемещаем keymap-файлы
        if [ -f config/charybdis.keymap ]; then
            mv config/charybdis.keymap '"${KEYMAP_PATH}"'/qwerty.keymap
        fi
        if [ -f config/colemak_dh.keymap ]; then
            mv config/colemak_dh.keymap '"${KEYMAP_PATH}"'/colemak_dh.keymap
        fi

        if [ "${BASE_DIR}" != "'"${PROJECT_ROOT_DIR}"'" ]; then
            apt-get -qq update > /dev/null && apt-get -q install -y -o Dpkg::Progress-Fancy="0" -o APT::Color="0" -o Dpkg::Use-Pty="0" tree > /dev/null

            BASE_CONFIG_PATH="${BASE_DIR}/'"${CONFIG_PATH}"'"
            mkdir -p "$BASE_CONFIG_PATH"
            cp -R "'"${CONFIG_PATH}"'"/* "$BASE_CONFIG_PATH/"

            if [ "${SHIELD}" != "settings_reset" ] && [ "${SHIELD}" != "null" ]; then
                # ИСПРАВЛЕНО: Копируем layouts.dtsi в директорию shield (как в workflow)
                if [ -f "$BASE_CONFIG_PATH/charybdis-layouts.dtsi" ]; then
                    mv -v "$BASE_CONFIG_PATH/charybdis-layouts.dtsi" \
                        "'"${PROJECT_ROOT_DIR}"'/boards/shields/charybdis-${FORMAT}/"
                fi

                # Копируем активный keymap
                cp -Rv "'"${PROJECT_ROOT_DIR}/${KEYMAP_PATH}"'/${KEYMAP}.keymap" \
                    "$BASE_CONFIG_PATH/charybdis.keymap"

                case "${FORMAT}" in
                    *bt*)
                        sed -i "s/device = <&vtrackball>;/device = <\&trackball>;/g" "$BASE_CONFIG_PATH/charybdis.keymap"
                        ;;
                esac
            fi
        fi

        # Удаляем лишние shields
        find "'"${PROJECT_ROOT_DIR}"'/boards/shields" \
            -mindepth 1 \
            -maxdepth 1 \
            ! -name "charybdis-${FORMAT}" \
            -exec rm -rf {} +

        cd "${BASE_DIR}"
        west init -l "${BASE_DIR}/'"${CONFIG_PATH}"'"
        west update
        west zephyr-export

        echo "Running: west build --pristine -s zmk/app -d ${BUILD_DIR} -b ${BOARD} ${EXTRA_WEST_ARGS} -- -DZMK_CONFIG=${BASE_DIR}/'"${CONFIG_PATH}"' ${EXTRA_CMAKE_ARGS} ${CMAKE_ARGS}"

        west build --pristine -s zmk/app -d "${BUILD_DIR}" -b "${BOARD}" ${EXTRA_WEST_ARGS} -- -DZMK_CONFIG="${BASE_DIR}/'"${CONFIG_PATH}"'" ${EXTRA_CMAKE_ARGS} ${CMAKE_ARGS}

        mkdir -p "${BUILD_DIR}/artifacts"
        if [ -f "${BUILD_DIR}/zephyr/zmk.uf2" ]; then
            cp "${BUILD_DIR}/zephyr/zmk.uf2" "${BUILD_DIR}/artifacts/${FINAL_ARTIFACT_NAME}.uf2"
        elif [ -f "${BUILD_DIR}/zephyr/zmk.'"${FALLBACK_BINARY}"'" ]; then
            cp "${BUILD_DIR}/zephyr/zmk.'"${FALLBACK_BINARY}"'" "${BUILD_DIR}/artifacts/${FINAL_ARTIFACT_NAME}.'"${FALLBACK_BINARY}"'"
        fi

        cp ${BUILD_DIR}/artifacts/* "'"${FIRMWARE_OUTPUT_DIR}"'/"
    '
done

echo "----------------------------------------------------"
echo "Сборка завершена!"
echo "Готовые файлы прошивки находятся в директории: ${FIRMWARE_OUTPUT_DIR}"
echo "----------------------------------------------------"