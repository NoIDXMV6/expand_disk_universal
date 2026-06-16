#!/bin/bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo_err() { echo -e "$*" >&2; }

if [[ $EUID -ne 0 ]]; then
    echo_err "${RED}Запустите с sudo.${NC}"
    exit 1
fi

install_if_missing() {
    local pkg=$1 cmd=$2
    if ! command -v "$cmd" &> /dev/null; then
        echo_err "${YELLOW}Установка $pkg...${NC}"
        if command -v apt &> /dev/null; then
            DEBIAN_FRONTEND=noninteractive apt update -qq && apt install -y -qq "$pkg"
        elif command -v yum &> /dev/null; then
            yum install -y -q "$pkg"
        elif command -v dnf &> /dev/null; then
            dnf install -y -q "$pkg"
        else
            echo_err "${RED}Не могу установить $pkg.${NC}"
            exit 1
        fi
    fi
}

install_if_missing "parted" "parted"
install_if_missing "gdisk" "sgdisk"
install_if_missing "cloud-guest-utils" "growpart" || install_if_missing "cloud-utils-growpart" "growpart"
install_if_missing "lvm2" "pvcreate"

# ---- Общие вспомогательные функции ----

get_disk_size_bytes() {
    blockdev --getsize64 "/dev/$1"
}

get_partition_info() {
    local disk=$1
    parted -s "/dev/$disk" unit s print 2>/dev/null | grep -E "^ [0-9]+" | awk '{print $1, $2, $3, $5}'
}

get_last_partition_num() {
    local disk=$1
    parted -s "/dev/$disk" unit s print 2>/dev/null | grep -E "^ [0-9]+" | sort -k3 -n | tail -1 | awk '{print $1}'
}

get_partition_start_sector() {
    local disk=$1 part_num=$2
    parted -s "/dev/$disk" unit s print 2>/dev/null | grep "^ $part_num" | awk '{print $2}' | sed 's/s//'
}

get_partition_end_sector() {
    local disk=$1 part_num=$2
    parted -s "/dev/$disk" unit s print 2>/dev/null | grep "^ $part_num" | awk '{print $3}' | sed 's/s//'
}

get_free_sectors_after_partition() {
    local disk=$1 part_num=$2
    local disk_sectors=$(blockdev --getsz "/dev/$disk")
    local end=$(get_partition_end_sector "$disk" "$part_num")
    local next_part=$(get_next_partition_num "$disk" "$part_num")
    if [[ -n "$next_part" ]]; then
        local next_start=$(get_partition_start_sector "$disk" "$next_part")
        echo $((next_start - end - 1))
    else
        echo $((disk_sectors - end - 1))
    fi
}

get_next_partition_num() {
    local disk=$1 part_num=$2
    local current_end=$(get_partition_end_sector "$disk" "$part_num")
    parted -s "/dev/$disk" unit s print 2>/dev/null | grep -E "^ [0-9]+" | awk -v ce="$current_end" '$2 > ce {print $1; exit}'
}

get_partition_type() {
    local disk=$1 part_num=$2
    parted -s "/dev/$disk" print 2>/dev/null | awk -v n="$part_num" '$1==n {print $5}'
}

get_fs_type() {
    lsblk -n -o FSTYPE "/dev/$1" 2>/dev/null | head -1
}

get_free_space_after_last_partition() {
    local disk=$1
    local last=$(get_last_partition_num "$disk")
    if [[ -z "$last" ]]; then
        echo "0"
        return
    fi
    local free_sectors=$(get_free_sectors_after_partition "$disk" "$last")
    echo $((free_sectors * 512))
}

can_expand_partition() {
    local disk=$1 part_num=$2
    local free=$(get_free_sectors_after_partition "$disk" "$part_num")
    if [[ $free -le 0 ]]; then
        return 1
    fi
    local ptype=$(get_partition_type "$disk" "$part_num")
    if [[ "$ptype" == "logical" ]]; then
        local ext_num=$(parted -s "/dev/$disk" print 2>/dev/null | awk '$5=="extended" {print $1}')
        if [[ -z "$ext_num" ]]; then
            return 1
        fi
        local next_primary=$(parted -s "/dev/$disk" unit s print 2>/dev/null | grep -E "^ [0-9]+" | awk -v e="$ext_num" '$1>e && $5=="primary" {print $1; exit}')
        if [[ -n "$next_primary" ]]; then
            return 1
        fi
        return 0
    elif [[ "$ptype" == "primary" ]]; then
        local next_part=$(get_next_partition_num "$disk" "$part_num")
        if [[ -z "$next_part" ]]; then
            return 0
        else
            local next_fs=$(get_fs_type "${disk}${next_part}")
            if [[ "$next_fs" == "swap" ]]; then
                return 0
            else
                return 1
            fi
        fi
    else
        return 1
    fi
}

# ---- Режим 1: расширение существующего раздела ----

suggest_best_partition() {
    local disk=$1
    echo_err "${BLUE}Анализ разделов диска /dev/$disk:${NC}"
    local all_parts=$(get_partition_info "$disk")
    local last=$(get_last_partition_num "$disk")
    local best=""
    local best_reason=""

    while read -r num start end type; do
        local can=""
        local reason=""
        if [[ "$type" == "extended" ]]; then
            can="${RED}нет${NC}"
            reason="(extended, не расширяется напрямую)"
        else
            if can_expand_partition "$disk" "$num"; then
                can="${GREEN}да${NC}"
                reason="(можно расширить)"
                if [[ "$num" == "$last" ]]; then
                    best="$num"
                    best_reason="последний раздел, за ним свободное место"
                fi
            else
                can="${RED}нет${NC}"
                local free=$(get_free_sectors_after_partition "$disk" "$num")
                if [[ $free -le 0 ]]; then
                    reason="(нет свободного места после раздела)"
                else
                    local next_part=$(get_next_partition_num "$disk" "$num")
                    if [[ -n "$next_part" ]]; then
                        local next_fs=$(get_fs_type "${disk}${next_part}")
                        if [[ "$next_fs" != "swap" ]]; then
                            reason="(после него идёт раздел $next_part, не swap)"
                        else
                            reason="(после него swap, но расширение возможно через перемещение)"
                        fi
                    else
                        reason="(неизвестная причина)"
                    fi
                fi
            fi
        fi
        echo_err "  Раздел $num ($type) от ${start}s до ${end}s — $can $reason"
    done <<< "$all_parts"

    if [[ -z "$best" ]]; then
        while read -r num start end type; do
            if [[ "$type" == "primary" ]] && can_expand_partition "$disk" "$num"; then
                best="$num"
                best_reason="первичный раздел, который можно расширить"
                break
            fi
        done <<< "$all_parts"
    fi

    if [[ -n "$best" ]]; then
        echo_err "${GREEN}Рекомендуется расширить раздел $best ($best_reason).${NC}"
    else
        echo_err "${YELLOW}Не найдено разделов, которые можно расширить. Возможно, нужно изменить разметку.${NC}"
    fi
    echo "$best"
}

expand_extended_if_needed() {
    local disk=$1 part_num=$2
    local ptype=$(get_partition_type "$disk" "$part_num")
    if [[ "$ptype" == "logical" ]]; then
        local ext_num=$(parted -s "/dev/$disk" print 2>/dev/null | awk '$5=="extended" {print $1}')
        if [[ -n "$ext_num" ]]; then
            echo_err "${YELLOW}Расширение extended-раздела /dev/${disk}${ext_num} до конца диска...${NC}"
            if ! parted -s "/dev/$disk" resizepart "$ext_num" 100% 2>/dev/null; then
                echo_err "${RED}Не удалось расширить extended-раздел: возможно, после него есть primary-раздел.${NC}"
                local next_primary=$(parted -s "/dev/$disk" unit s print 2>/dev/null | grep -E "^ [0-9]+" | awk -v e="$ext_num" '$1>e && $5=="primary" {print $1; exit}')
                if [[ -n "$next_primary" ]]; then
                    echo_err "${YELLOW}Рекомендуется расширить primary-раздел /dev/${disk}${next_primary}.${NC}"
                fi
                exit 1
            fi
            partprobe "/dev/$disk"
            sleep 2
        fi
    fi
}

grow_partition() {
    local disk=$1 part_num=$2
    local size_sectors=${3:-}

    expand_extended_if_needed "$disk" "$part_num"

    local cmd="growpart /dev/$disk $part_num"
    if [[ -n "$size_sectors" ]]; then
        cmd="$cmd $size_sectors"
    fi
    echo_err "${GREEN}Расширение раздела /dev/$disk$part_num${size_sectors:+ до $size_sectors секторов}...${NC}"
    local output
    set +e
    output=$($cmd 2>&1)
    local ret=$?
    set -e
    echo_err "$output"
    if [[ $ret -eq 2 ]]; then
        echo_err "${YELLOW}Раздел не изменился. Возможно, он уже максимального размера или указан неверный размер.${NC}"
        exit 1
    elif [[ $ret -ne 0 ]]; then
        echo_err "${RED}Ошибка growpart (код $ret).${NC}"
        exit 1
    fi
    echo_err "${GREEN}Раздел расширен.${NC}"
}

expand_lvm() {
    local partition=$1
    echo_err "${BLUE}Расширение LVM...${NC}"
    pvresize "/dev/$partition"
    local vg_name=$(pvs --noheadings -o vg_name "/dev/$partition" | tr -d ' ')
    for lv in $(lvs --noheadings -o lv_name "$vg_name" | grep -v swap | tr -d ' '); do
        echo_err "Расширение LV $lv..."
        lvextend -r -l +100%FREE "/dev/$vg_name/$lv"
    done
}

expand_regular_fs() {
    local partition=$1
    local fs=$(get_fs_type "$partition")
    case "$fs" in
        ext*) resize2fs "/dev/$partition" ;;
        xfs)  xfs_growfs "$(findmnt -n -o TARGET "/dev/$partition")" ;;
        *)    echo_err "${RED}Неизвестная ФС $fs${NC}" ;;
    esac
}

relocate_swap() {
    local disk=$1 target_num=$2 swap_num=$3
    local size_sectors=${4:-}

    local swap_part="/dev/${disk}${swap_num}"
    local swap_uuid=$(blkid -s UUID -o value "$swap_part" 2>/dev/null || true)
    local swap_start=$(get_partition_start_sector "$disk" "$swap_num")

    echo_err "${YELLOW}Будет удалён swap-раздел $swap_part, расширен /dev/${disk}${target_num}, затем swap создан в конце диска.${NC}"
    echo -n -e "${YELLOW}Продолжить? (y/n): ${NC}" >&2
    read -r confirm
    [[ "$confirm" == "y" ]] || exit 1

    swapoff "$swap_part" 2>/dev/null || true
    cp /etc/fstab /etc/fstab.bak.$(date +%Y%m%d_%H%M%S)
    sed -i "/$(basename "$swap_part")\|$swap_uuid/d" /etc/fstab
    parted "/dev/$disk" rm "$swap_num"
    grow_partition "$disk" "$target_num" "$size_sectors"
    partprobe "/dev/$disk"
    sleep 2

    local new_start=$(get_partition_end_sector "$disk" "$target_num")
    local new_start_s=$((new_start + 1))
    parted "/dev/$disk" mkpart primary linux-swap "${new_start_s}s" 100%
    local new_swap_num=$(get_last_partition_num "$disk")
    local new_swap_part="/dev/${disk}${new_swap_num}"
    mkswap "$new_swap_part"
    local new_uuid=$(blkid -s UUID -o value "$new_swap_part")
    echo "UUID=$new_uuid none swap sw 0 0" >> /etc/fstab
    swapon "$new_swap_part"
    echo_err "${GREEN}Swap перемещён в конец диска.${NC}"
}

mode_expand_existing() {
    echo_err "${GREEN}=== Режим: расширение существующего раздела ===${NC}"

    disk=$(select_disk)
    echo_err "${BLUE}Работаем с диском: /dev/$disk${NC}"

    check_expand_possible "$disk"

    echo_err "${BLUE}Текущие разделы:${NC}"
    lsblk "/dev/$disk" >&2

    suggested=$(suggest_best_partition "$disk")

    echo -n -e "${YELLOW}Введите номер раздела для расширения (рекомендуется $suggested): ${NC}" >&2
    read -r target_num
    target_part="/dev/${disk}${target_num}"
    if [[ ! -b "$target_part" ]]; then
        echo_err "${RED}Раздел $target_part не существует.${NC}"
        exit 1
    fi

    if ! can_expand_partition "$disk" "$target_num"; then
        echo_err "${RED}Выбранный раздел не может быть расширен в текущей конфигурации.${NC}"
        exit 1
    fi

    local free_sectors=$(get_free_sectors_after_partition "$disk" "$target_num")
    local free_bytes=$((free_sectors * 512))
    echo_err "${BLUE}Доступно свободного места после раздела: $((free_bytes / 1024 / 1024 / 1024)) ГБ (${free_sectors} секторов).${NC}"
    echo -n -e "${YELLOW}Введите размер для расширения (например, 10G, 500M) или 'all' для всего свободного места: ${NC}" >&2
    read -r size_input

    local size_sectors=""
    if [[ "$size_input" == "all" ]]; then
        size_sectors=""
    else
        local num=$(echo "$size_input" | sed -r 's/([0-9.]+)[GgMm]?.*/\1/')
        local unit=$(echo "$size_input" | sed -r 's/[0-9.]+([GgMm])?.*/\1/' | tr '[:upper:]' '[:lower:]')
        if [[ -z "$num" ]]; then
            echo_err "${RED}Неверный формат размера.${NC}"
            exit 1
        fi
        local bytes
        case "$unit" in
            g) bytes=$(echo "$num * 1024 * 1024 * 1024" | bc) ;;
            m) bytes=$(echo "$num * 1024 * 1024" | bc) ;;
            *) bytes=$(echo "$num * 1024 * 1024 * 1024" | bc) ;;
        esac
        bytes=${bytes%.*}
        local req_sectors=$((bytes / 512))
        if [[ $req_sectors -le 0 ]]; then
            echo_err "${RED}Указанный размер слишком мал.${NC}"
            exit 1
        fi
        if [[ $req_sectors -gt $free_sectors ]]; then
            echo_err "${RED}Запрошенный размер превышает доступное свободное место. Будет использовано всё свободное место.${NC}"
            size_sectors=""
        else
            size_sectors=$req_sectors
        fi
    fi

    is_lvm=$(blkid "$target_part" | grep -q "LVM2_member" && echo "yes" || echo "no")

    local last_part=$(get_last_partition_num "$disk")
    if [[ "$target_num" -ne "$last_part" ]]; then
        next_num=$(get_next_partition_num "$disk" "$target_num")
        next_part="/dev/${disk}${next_num}"
        next_fs=$(get_fs_type "${disk}${next_num}")
        echo_err "${YELLOW}Внимание: раздел $target_num не последний. После него идёт раздел $next_num (ФС: $next_fs).${NC}"

        if [[ "$next_fs" == "swap" ]]; then
            echo_err "Выберите действие:"
            echo "  1) Расширить последний раздел (swap)"
            echo "  2) Переместить swap в конец и расширить раздел $target_num"
            echo -n -e "${YELLOW}Ваш выбор (1/2): ${NC}" >&2
            read -r action
            case $action in
                1)
                    grow_partition "$disk" "$next_num" "$size_sectors"
                    partprobe "/dev/$disk"
                    sleep 2
                    mkswap "$next_part"
                    echo_err "${GREEN}Swap расширен.${NC}"
                    if [[ "$is_lvm" != "yes" ]]; then
                        echo_err "${YELLOW}Целевой раздел не был расширен, так как вы выбрали swap.${NC}"
                        exit 0
                    fi
                    ;;
                2)
                    relocate_swap "$disk" "$target_num" "$next_num" "$size_sectors"
                    ;;
                *)
                    echo_err "${RED}Неверный выбор. Выход.${NC}"
                    exit 1
                    ;;
            esac
        else
            echo_err "${RED}Следующий раздел не swap, автоматическое расширение невозможно.${NC}"
            exit 1
        fi
    else
        grow_partition "$disk" "$target_num" "$size_sectors"
        partprobe "/dev/$disk"
        sleep 2
    fi

    if [[ "$is_lvm" == "yes" ]]; then
        expand_lvm "${disk}${target_num}"
    else
        expand_regular_fs "${disk}${target_num}"
    fi

    echo_err "${GREEN}=== Готово! Новое состояние диска ===${NC}"
    lsblk "/dev/$disk" >&2
}

# ---- Режим 2: добавление нового диска ----

# Исправленная функция определения неиспользуемых дисков
get_unused_disks() {
    local used_disks=()
    
    # 1. Диски, на которых есть смонтированные разделы
    while read -r line; do
        local dev=$(echo "$line" | awk '{print $1}')
        # dev может быть sda1, sdb, etc. Извлекаем базовый диск
        local disk=$(echo "$dev" | sed -r 's/([a-z]+)[0-9]+.*/\1/' | sed 's/p[0-9]*$//')
        if [[ -n "$disk" && -b "/dev/$disk" ]]; then
            used_disks+=("$disk")
        fi
    done < <(lsblk -l -o NAME,MOUNTPOINT | grep -v "MOUNTPOINT" | grep -E ".+/.+" || true)

    # 2. Диски, которые содержат LVM PV
    while read -r pv; do
        local dev=$(echo "$pv" | awk '{print $1}')
        local disk=$(echo "$dev" | sed -r 's/([a-z]+)[0-9]+.*/\1/' | sed 's/p[0-9]*$//')
        if [[ -n "$disk" && -b "/dev/$disk" ]]; then
            used_disks+=("$disk")
        fi
    done < <(pvs --noheadings -o pv_name 2>/dev/null || true)

    # 3. Диск, на котором смонтирован корень (дополнительная проверка)
    local root_disk=$(findmnt -n -o SOURCE / | sed -r 's/([a-z]+)[0-9]+.*/\1/' | sed 's/p[0-9]*$//')
    if [[ -n "$root_disk" && -b "/dev/$root_disk" ]]; then
        used_disks+=("$root_disk")
    fi

    # Убираем дубликаты
    local unique_used=()
    for d in "${used_disks[@]}"; do
        if [[ ! " ${unique_used[@]} " =~ " $d " ]]; then
            unique_used+=("$d")
        fi
    done

    # Получаем список всех базовых дисков
    local all_disks=()
    for dev in /dev/sd* /dev/hd* /dev/vd* /dev/nvme*n*; do
        if [[ -b "$dev" && ! "$dev" =~ [0-9] ]]; then
            local disk=$(basename "$dev")
            all_disks+=("$disk")
        fi
    done

    # Находим неиспользуемые
    local unused=()
    for disk in "${all_disks[@]}"; do
        local used=0
        for used_disk in "${unique_used[@]}"; do
            if [[ "$disk" == "$used_disk" ]]; then
                used=1
                break
            fi
        done
        if [[ $used -eq 0 ]]; then
            unused+=("$disk")
        fi
    done

    echo "${unused[@]}"
}

select_disk_new() {
    local unused=($(get_unused_disks))
    if [[ ${#unused[@]} -eq 0 ]]; then
        echo_err "${RED}Не найдено неиспользуемых дисков.${NC}"
        exit 1
    fi
    echo_err "${BLUE}Доступные неиспользуемые диски:${NC}"
    for d in "${unused[@]}"; do
        local size=$(lsblk -d -o SIZE -n "/dev/$d" 2>/dev/null || echo "?")
        echo_err "  /dev/$d ($size)"
    done
    echo -n -e "${YELLOW}Введите имя диска (например, sdb): ${NC}" >&2
    read -r disk
    if [[ ! -b "/dev/$disk" ]]; then
        echo_err "${RED}Диск /dev/$disk не существует.${NC}"
        exit 1
    fi
    # Проверим, действительно ли он не используется (на всякий случай)
    local used=0
    for d in "${unused[@]}"; do
        if [[ "$d" == "$disk" ]]; then
            used=1
            break
        fi
    done
    if [[ $used -eq 0 ]]; then
        echo_err "${YELLOW}Предупреждение: диск /dev/$disk, возможно, уже используется. Продолжить? (y/n)${NC}" >&2
        read -r confirm
        [[ "$confirm" == "y" ]] || exit 1
    fi
    echo "$disk"
}

mode_add_new_disk() {
    echo_err "${GREEN}=== Режим: добавление нового диска ===${NC}"
    echo_err "Этот режим позволяет использовать новый диск как LVM физический том или как отдельный раздел."

    disk=$(select_disk_new)
    echo_err "${BLUE}Работаем с диском: /dev/$disk${NC}"

    # Проверяем, есть ли на диске разделы
    local parts=$(lsblk -l -o NAME -n "/dev/$disk" | grep -E "^${disk}[0-9]+$|^${disk}p[0-9]+$" | wc -l)
    if [[ $parts -gt 0 ]]; then
        echo_err "${YELLOW}На диске уже есть разделы. Это может означать, что диск не пуст.${NC}"
        echo_err "Текущие разделы:"
        lsblk "/dev/$disk" >&2
        echo -n -e "${YELLOW}Продолжить, стерев все разделы? (y/n): ${NC}" >&2
        read -r confirm
        if [[ "$confirm" != "y" ]]; then
            exit 1
        fi
        dd if=/dev/zero of="/dev/$disk" bs=1M count=1 2>/dev/null
        partprobe "/dev/$disk"
        sleep 1
    fi

    echo_err "Выберите способ использования диска:"
    echo "  1) Добавить как LVM физический том (pvcreate) и расширить существующую VG"
    echo "  2) Создать отдельный раздел с файловой системой (не LVM)"
    echo -n -e "${YELLOW}Ваш выбор (1/2): ${NC}" >&2
    read -r choice

    case $choice in
        1)
            echo_err "${BLUE}Инициализация диска как LVM PV...${NC}"
            pvcreate "/dev/$disk"
            echo_err "${GREEN}PV создан.${NC}"

            echo_err "${BLUE}Доступные группы томов (VG):${NC}"
            vgs
            echo -n -e "${YELLOW}Введите имя VG для добавления (или создайте новую, введя новое имя): ${NC}" >&2
            read -r vg_name

            if vgs "$vg_name" &>/dev/null; then
                echo_err "Добавление PV в существующую VG $vg_name..."
                vgextend "$vg_name" "/dev/$disk"
            else
                echo_err "Создание новой VG $vg_name..."
                vgcreate "$vg_name" "/dev/$disk"
            fi
            echo_err "${GREEN}VG расширена.${NC}"

            echo_err "${BLUE}Доступные логические тома в VG $vg_name:${NC}"
            lvs "$vg_name"
            echo -n -e "${YELLOW}Введите имя LV для расширения (или 'all' для всех): ${NC}" >&2
            read -r lv_name

            if [[ "$lv_name" == "all" ]]; then
                for lv in $(lvs --noheadings -o lv_name "$vg_name" | grep -v swap | tr -d ' '); do
                    echo_err "Расширение LV $lv на всё свободное место..."
                    lvextend -r -l +100%FREE "/dev/$vg_name/$lv"
                done
            else
                if ! lvs "$vg_name/$lv_name" &>/dev/null; then
                    echo_err "${RED}LV $lv_name не существует.${NC}"
                    exit 1
                fi
                local free_pe=$(vgs --noheadings -o free_count "$vg_name" | tr -d ' ')
                local pe_size=$(vgs --noheadings -o pe_size "$vg_name" | tr -d ' ' | sed 's/[^0-9]//g')
                local free_bytes=$((free_pe * pe_size * 1024))
                echo_err "${BLUE}Доступно свободного места в VG: $((free_bytes / 1024 / 1024 / 1024)) ГБ.${NC}"
                echo -n -e "${YELLOW}Введите размер для расширения (например, 10G, 500M) или 'all' для всего свободного места: ${NC}" >&2
                read -r size_input
                if [[ "$size_input" == "all" ]]; then
                    lvextend -r -l +100%FREE "/dev/$vg_name/$lv_name"
                else
                    local num=$(echo "$size_input" | sed -r 's/([0-9.]+)[GgMm]?.*/\1/')
                    local unit=$(echo "$size_input" | sed -r 's/[0-9.]+([GgMm])?.*/\1/' | tr '[:upper:]' '[:lower:]')
                    if [[ -z "$num" ]]; then
                        echo_err "${RED}Неверный формат.${NC}"
                        exit 1
                    fi
                    local bytes
                    case "$unit" in
                        g) bytes=$(echo "$num * 1024 * 1024 * 1024" | bc) ;;
                        m) bytes=$(echo "$num * 1024 * 1024" | bc) ;;
                        *) bytes=$(echo "$num * 1024 * 1024 * 1024" | bc) ;;
                    esac
                    bytes=${bytes%.*}
                    lvextend -r -L "${bytes}B" "/dev/$vg_name/$lv_name"
                fi
            fi
            echo_err "${GREEN}Расширение LV завершено.${NC}"
            ;;
        2)
            echo_err "Выберите файловую систему:"
            echo "  1) ext4"
            echo "  2) xfs"
            echo -n -e "${YELLOW}Ваш выбор (1/2): ${NC}" >&2
            read -r fs_choice
            case $fs_choice in
                1) fs="ext4" ;;
                2) fs="xfs" ;;
                *) echo_err "Неверный выбор"; exit 1 ;;
            esac

            echo_err "Создание раздела на весь диск..."
            parted -s "/dev/$disk" mklabel gpt
            parted -s "/dev/$disk" mkpart primary 0% 100%
            partprobe "/dev/$disk"
            sleep 2
            local part_name="${disk}1"
            echo_err "Форматирование /dev/$part_name в $fs..."
            mkfs -t "$fs" "/dev/$part_name"

            echo -n -e "${YELLOW}Введите точку монтирования (например, /mnt/newdisk): ${NC}" >&2
            read -r mount_point
            if [[ ! -d "$mount_point" ]]; then
                mkdir -p "$mount_point"
                echo_err "Создана директория $mount_point"
            fi

            echo_err "Монтирование..."
            mount "/dev/$part_name" "$mount_point"
            echo "Добавление записи в /etc/fstab"
            local uuid=$(blkid -s UUID -o value "/dev/$part_name")
            echo "UUID=$uuid $mount_point $fs defaults 0 0" >> /etc/fstab
            echo_err "${GREEN}Диск добавлен и смонтирован в $mount_point.${NC}"
            ;;
        *)
            echo_err "Неверный выбор"
            exit 1
            ;;
    esac

    echo_err "${GREEN}=== Готово! ===${NC}"
    lsblk "/dev/$disk" >&2
}

# ---- Общие функции для выбора диска и проверки (используются в режиме 1) ----

select_disk() {
    echo_err "${BLUE}Доступные диски:${NC}"
    lsblk -d -o NAME,SIZE,TYPE,MODEL >&2
    echo -n -e "${YELLOW}Введите имя диска (например, sda): ${NC}" >&2
    read -r disk
    if [[ ! -b "/dev/$disk" ]]; then
        echo_err "${RED}Диск /dev/$disk не существует.${NC}"
        exit 1
    fi
    echo "$disk"
}

check_expand_possible() {
    local disk=$1
    local free=$(get_free_space_after_last_partition "$disk")
    if [[ $free -lt 1048576 ]]; then
        echo_err "${YELLOW}Нет свободного неразмеченного места после последнего раздела.${NC}"
        echo_err "Свободно: $((free / 1024 / 1024)) МБ. Расширение невозможно."
        echo_err "Увеличьте виртуальный диск в гипервизоре и запустите скрипт снова."
        exit 1
    fi
    echo_err "${GREEN}Обнаружено свободное место: $((free / 1024 / 1024)) МБ.${NC}"
}

# ---- Главное меню ----

main() {
    echo_err "${GREEN}=== Универсальный скрипт управления дисками и LVM ===${NC}"
    echo_err "Выберите режим:"
    echo "  1) Расширить существующий раздел (увеличение диска в гипервизоре)"
    echo "  2) Добавить новый диск (LVM или отдельный раздел)"
    echo -n -e "${YELLOW}Ваш выбор (1/2): ${NC}" >&2
    read -r mode
    case $mode in
        1) mode_expand_existing ;;
        2) mode_add_new_disk ;;
        *) echo_err "Неверный выбор"; exit 1 ;;
    esac
}

main
