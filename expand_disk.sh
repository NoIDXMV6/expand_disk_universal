#!/bin/bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Вывод в stderr с цветом
echo_err() { echo -e "$*" >&2; }

# Проверка root
if [[ $EUID -ne 0 ]]; then
    echo_err "${RED}Запустите с sudo.${NC}"
    exit 1
fi

# Установка пакетов (тихо)
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

# ---- Функции работы с диском ----

get_disk_size_bytes() {
    blockdev --getsize64 "/dev/$1"
}

get_free_space_after_last_partition() {
    local disk=$1
    local last_part=$(lsblk -l -o NAME -n "/dev/$disk" | grep -E "^${disk}[0-9]+$|^${disk}p[0-9]+$" | tail -1)
    if [[ -z "$last_part" ]]; then
        echo "0"
        return
    fi
    local part_end_bytes=$(parted "/dev/$disk" unit B print 2>/dev/null | grep "^ $(echo "$last_part" | grep -oE '[0-9]+$')" | awk '{print $3}' | sed 's/B//')
    local disk_size=$(get_disk_size_bytes "$disk")
    echo $((disk_size - part_end_bytes))
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

get_partitions() {
    lsblk -l -o NAME -n "/dev/$1" | grep -E "^${1}[0-9]+$|^${1}p[0-9]+$" | sort -V
}

is_last_partition() {
    local disk=$1 part_num=$2
    local last=$(get_partitions "$disk" | tail -1 | grep -oE '[0-9]+$')
    [[ "$part_num" -eq "$last" ]]
}

get_next_partition() {
    local disk=$1 part_num=$2
    get_partitions "$disk" | grep -oE '[0-9]+$' | awk -v p="$part_num" '$1>p {print $1; exit}'
}

get_fs_type() {
    lsblk -n -o FSTYPE "/dev/$1" | head -1
}

grow_partition() {
    local disk=$1 part_num=$2
    echo_err "${GREEN}Расширение раздела /dev/$disk$part_num на всё свободное место...${NC}"
    local output
    set +e
    output=$(growpart "/dev/$disk" "$part_num" 2>&1)
    local ret=$?
    set -e
    echo_err "$output"
    if [[ $ret -eq 2 ]]; then
        echo_err "${YELLOW}Раздел не изменился. Возможно, он уже максимального размера.${NC}"
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
    local swap_part="/dev/${disk}${swap_num}"
    local swap_uuid=$(blkid -s UUID -o value "$swap_part" 2>/dev/null || true)
    local swap_start=$(parted "/dev/$disk" unit s print | grep "^ ${swap_num}" | awk '{print $2}' | sed 's/s//')
    
    echo_err "${YELLOW}Будет удалён swap-раздел $swap_part, расширен /dev/${disk}${target_num}, затем swap создан в конце диска.${NC}"
    echo -n -e "${YELLOW}Продолжить? (y/n): ${NC}" >&2
    read -r confirm
    [[ "$confirm" == "y" ]] || exit 1
    
    swapoff "$swap_part" 2>/dev/null || true
    cp /etc/fstab /etc/fstab.bak.$(date +%Y%m%d_%H%M%S)
    sed -i "/$(basename "$swap_part")\|$swap_uuid/d" /etc/fstab
    parted "/dev/$disk" rm "$swap_num"
    grow_partition "$disk" "$target_num"
    partprobe "/dev/$disk"
    sleep 2
    parted "/dev/$disk" mkpart primary linux-swap "$swap_start"s 100%
    local new_swap_num=$(get_partitions "$disk" | tail -1 | grep -oE '[0-9]+$')
    local new_swap_part="/dev/${disk}${new_swap_num}"
    mkswap "$new_swap_part"
    local new_uuid=$(blkid -s UUID -o value "$new_swap_part")
    echo "UUID=$new_uuid none swap sw 0 0" >> /etc/fstab
    swapon "$new_swap_part"
    echo_err "${GREEN}Swap перемещён в конец диска.${NC}"
}

# ---- Главная функция ----
main() {
    echo_err "${GREEN}=== Универсальный скрипт расширения диска (LVM и обычные разделы) ===${NC}"
    
    disk=$(select_disk)
    echo_err "${BLUE}Работаем с диском: /dev/$disk${NC}"
    
    check_expand_possible "$disk"
    
    echo_err "${BLUE}Текущие разделы:${NC}"
    lsblk "/dev/$disk" >&2
    
    echo -n -e "${YELLOW}Введите номер раздела для расширения (например, 3): ${NC}" >&2
    read -r target_num
    target_part="/dev/${disk}${target_num}"
    if [[ ! -b "$target_part" ]]; then
        echo_err "${RED}Раздел $target_part не существует.${NC}"
        exit 1
    fi
    
    is_lvm=$(blkid "$target_part" | grep -q "LVM2_member" && echo "yes" || echo "no")
    
    if ! is_last_partition "$disk" "$target_num"; then
        next_num=$(get_next_partition "$disk" "$target_num")
        next_part="/dev/${disk}${next_num}"
        next_fs=$(get_fs_type "$next_part")
        echo_err "${YELLOW}Внимание: раздел $target_num не последний. После него идёт раздел $next_num (ФС: $next_fs).${NC}"
        
        if [[ "$next_fs" == "swap" ]]; then
            echo_err "Выберите действие:"
            echo "  1) Расширить последний раздел (swap)"
            echo "  2) Переместить swap в конец и расширить раздел $target_num"
            echo -n -e "${YELLOW}Ваш выбор (1/2): ${NC}" >&2
            read -r action
            case $action in
                1)
                    grow_partition "$disk" "$next_num"
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
                    relocate_swap "$disk" "$target_num" "$next_num"
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
        grow_partition "$disk" "$target_num"
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

main
