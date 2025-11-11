#!/bin/bash
#
# diskimager.sh - Masowe klonowanie dysków (obraz 1:1)
# Wersja: 2.1 FINAL (Automated Boot Fix)
# Data: 2025-11-02
#

set -euo pipefail

# ============================================================================
# KONFIGURACJA
# ============================================================================

# Gdzie trzymać obrazy
IMAGES_DIR="/mnt/ssd/disk-images"

# Kompresja obrazu: none | gz | zst
COMPRESS="none"

# Blok dla dd/pv (4M jest optymalny dla nowoczesnych dysków)
DD_BS="4M"

# Log
LOG_FILE="/var/log/diskimager.log"

# Domyślny profil OS (jeśli user tylko enter)
DEFAULT_OS_PROFILE="windows"

# Wzorce urządzeń
TARGET_DISK_PATTERNS="sd* nvme*"
SOURCE_DISK_PATTERN="sd* nvme*"

# Czy przy przywracaniu robić brutalne czyszczenie GPT/MPT: yes/no
FORCE_ZAP_TARGETS="no"

# Tryb naprawy Windows boot:
#   none  - nic nie robić
#   safe  - tylko upewnić się, że jest EFI i fallback, NIE kasować BCD
WINDOWS_BOOT_FIX_MODE="safe"

# Ile z obrazu porównywać przy weryfikacji (MB)
VERIFY_MB=100

# ============================================================================
# FUNKCJE POMOCNICZE
# ============================================================================

log() {
    printf "[%s] %s\n" "$(date -Iseconds)" "$*" | tee -a "$LOG_FILE"
}

error_exit() {
    log "BŁĄD: $*"
    exit 1
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error_exit "Skrypt wymaga uprawnień root. Uruchom: sudo $0"
    fi
}

check_dependencies() {
    local missing=()
    # Dodano ntfsfix
    for cmd in pv dd lsblk wipefs sgdisk partprobe blkid parted blockdev findmnt ntfsfix; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        error_exit "Brakujące narzędzia: ${missing[*]}. (Zainstaluj np. ntfs-3g)"
    fi
}

# Ulepszone wykrywanie dysku systemowego (dla LVM/RAID/NVMe)
detect_system_disk() {
    local root_src
    root_src="$(findmnt -n -o SOURCE / || true)"
    if [[ -z "$root_src" ]]; then
        echo "sda" # Fallback
        return
    fi

    local dev
    dev=$(lsblk -no PKNAME "$root_src" 2>/dev/null | head -1 || true)
    
    if [[ -z "$dev" ]]; then
        dev="$(basename "$root_src" | sed 's|^/dev/||')"
        dev="$(echo "$dev" | sed 's/[0-9]\+$//')" # np. sda3 -> sda
        dev="$(echo "$dev" | sed 's|p[0-9]\+$||')" # np. nvme0n1p3 -> nvme0n1
    fi

    [[ -z "$dev" ]] && dev="sda" # Ostateczny fallback
    echo "$dev"
}


refresh_disks() {
    log "Odświeżam listę dysków..."
    udevadm settle 2>/dev/null || true
    for h in /sys/class/scsi_host/host*/scan; do
        [[ -f "$h" ]] && echo "- - -" > "$h" 2>/dev/null || true
    done
    partprobe -s 2>/dev/null || true
    sleep 1
}

list_disks() {
    local pattern="$1"
    local exclude_system="${2:-true}"
    local system_disk="$3"

    refresh_disks

    local disks=()

    for p in $pattern; do
        for devpath in /dev/$p; do
            [[ -e "$devpath" ]] || continue
            local name
            name="$(basename "$devpath")"

            local type
            type=$(lsblk -ndo TYPE "$devpath" 2>/dev/null || echo "")
            [[ "$type" == "disk" ]] || continue

            [[ "$name" =~ ^loop ]] && continue
            [[ "$name" =~ ^ram ]] && continue
            [[ "$name" =~ ^sr ]] && continue

            if [[ "$exclude_system" == "true" && "$name" == "$system_disk" ]]; then
                continue
            fi

            local size
            size=$(lsblk -ndo SIZE "$devpath" 2>/dev/null || echo "?")
            local model
            model=$(lsblk -ndo MODEL "$devpath" 2>/dev/null | xargs || echo "Unknown")

            disks+=("$name")
            printf "   %-12s %-10s %s\n" "$name" "$size" "$model"
        done
    done

    echo "${disks[@]}"
}

# ============================================================================
# TWORZENIE OBRAZU
# ============================================================================

create_image() {
    log "=== TWORZENIE OBRAZU ==="

    local system_disk
    system_disk="$(detect_system_disk)"

    echo ""
    echo "Dostępne dyski źródłowe ($SOURCE_DISK_PATTERN):"
    local available_sources
    available_sources=$(list_disks "$SOURCE_DISK_PATTERN" false "$system_disk")

    if [[ -z "$available_sources" ]]; then
        error_exit "Nie znaleziono dysków źródłowych"
    fi

    echo ""
    echo "Dostępne: $available_sources"
    echo ""
    read -p "Podaj źródło (np. sda / nvme0n1): " source_disk
    source_disk=$(echo "$source_disk" | xargs | sed 's|^/dev/||')

    if [[ ! -b "/dev/$source_disk" ]]; then
        error_exit "Dysk /dev/$source_disk nie istnieje"
    fi

    if [[ "$source_disk" == "$system_disk" ]]; then
        echo "UWAGA: To dysk systemowy!"
        echo "Obraz może nie być spójny (filesystem jest aktywny)."
        read -p "Czy NA PEWNO chcesz zrobić obraz? [y/N]: " confirm
        [[ "$confirm" =~ ^[Yy]$ ]] || error_exit "Anulowano"
    fi

    echo ""
    echo "PAMIĘTAJ: Obraz 'matki' Windows powinien być zrobiony po SYSPEP!"
    echo ""
    read -p "Podaj etykietę (np. W11-PC01-SYSPEP): " label
    label=$(echo "$label" | xargs | tr ' ' '-')
    [[ -z "$label" ]] && error_exit "Etykieta nie może być pusta"

    mkdir -p "$IMAGES_DIR"

    local timestamp
    timestamp=$(date +%Y%m%d-%H%M%S)
    local ext="img"
    [[ "$COMPRESS" == "zst" ]] && ext="img.zst"
    [[ "$COMPRESS" == "gz" ]] && ext="img.gz"

    local output_file="$IMAGES_DIR/${timestamp}_${label}.${ext}"

    log "Tworzę obraz: /dev/$source_disk -> $output_file"

    local disk_size
    disk_size=$(blockdev --getsize64 "/dev/$source_disk")
    log "Rozmiar: $(numfmt --to=iec-i --suffix=B "$disk_size")"

    echo ""
    echo "START: $(date)"

    trap 'log "Przerwano tworzenie obrazu"; rm -f "$output_file.part"; exit 1' INT

    case "$COMPRESS" in
        zst)
            command -v zstd &>/dev/null || error_exit "zstd nie jest zainstalowane"
            pv -s "$disk_size" "/dev/$source_disk" | zstd -T0 -3 -o "$output_file"
            ;;
        gz)
            pv -s "$disk_size" "/dev/$source_disk" | gzip -1 > "$output_file"
            ;;
        none)
            pv -s "$disk_size" "/dev/$source_disk" > "$output_file"
            ;;
        *)
            error_exit "Nieznany typ kompresji: $COMPRESS"
            ;;
    esac

    trap - INT
    sync
    echo ""
    echo "KONIEC: $(date)"
    log "Obraz utworzony: $output_file"

    local file_size
    file_size=$(stat -c%s "$output_file")
    log "Rozmiar pliku: $(numfmt --to=iec-i --suffix=B "$file_size")"

    echo ""
    echo "Gotowe! Naciśnij Enter..."
    read
}

# ============================================================================
# RÓWNOLEGŁY ZAPIS
# ============================================================================

parallel_write_image() {
    local image_file="$1"
    shift
    local disks=("$@")

    local decompress_cmd="cat"
    if [[ "$image_file" == *.zst ]]; then
        decompress_cmd="zstd -dc"
    elif [[ "$image_file" == *.gz ]]; then
        decompress_cmd="gzip -dc"
    fi

    if [[ ${#disks[@]} -eq 1 ]]; then
        log "Zapisuję na /dev/${disks[0]}..."
        $decompress_cmd "$image_file" | dd of="/dev/${disks[0]}" bs="$DD_BS" iflag=fullblock conv=fsync oflag=direct status=progress
        return 0
    fi

    log "Zapisuję równolegle na ${#disks[@]} dyski..."

    local fifos=()
    local pids=()
    
    trap 'log "Przerwano zapis"; kill 0; rm -f /tmp/diskimager_*_$$.fifo; exit 1' INT

    for disk in "${disks[@]}"; do
        local fifo="/tmp/diskimager_${disk}_$$.fifo"
        mkfifo "$fifo"
        fifos+=("$fifo")

        (
            dd if="$fifo" of="/dev/$disk" bs="$DD_BS" iflag=fullblock conv=fsync oflag=direct status=progress 2>&1 | \
            stdbuf -oL sed "s/^/[$disk] /"
        ) &
        pids+=($!)
    done

    $decompress_cmd "$image_file" | tee "${fifos[@]}" > /dev/null

    local exit_status=0
    for pid in "${pids[@]}"; do
        wait "$pid" || exit_status=1
    done

    for fifo in "${fifos[@]}"; do
        rm -f "$fifo"
    done
    
    trap - INT

    if [[ $exit_status -ne 0 ]]; then
        error_exit "Jeden z procesów dd zakończył się błędem"
    fi

    log "Zapis równoległy zakończony"
}

# ============================================================================
# NAPRAWA WINDOWS (SAFE) - Wersja AUTOMATYCZNA
# ============================================================================

fix_windows_boot_safe() {
    local disk="$1"
    log "[$disk] === NAPRAWA BOOTLOADER (SAFE, AUTOMATYCZNA) ==="

    partprobe "/dev/$disk" 2>/dev/null || true
    blockdev --rereadpt "/dev/$disk" 2>/dev/null || true
    sleep 2

    local efi_part=""
    local part_num=""

    # 1. Znajdź partycję EFI po typie (GPT: C12A7328-F81F-11D2-BA4B-00A0C93EC93B) lub FAT32
    # Używamy lsblk do uzyskania nazwy partycji
    local part_data
    part_data=$(lsblk -ln "/dev/$disk" -o NAME,PARTTYPE,FSTYPE 2>/dev/null)

    efi_part=$(echo "$part_data" | grep -i 'c12a7328-f81f-11d2-ba4b-00a0c93ec93b' | awk '{print $1}' | head -1)
    if [[ -z "$efi_part" ]]; then
        efi_part=$(echo "$part_data" | grep -iE 'vfat|fat32' | head -1 | awk '{print $1}')
    fi

    if [[ -z "$efi_part" ]]; then
        log "[$disk] Brak partycji EFI – pomijam"
        return 0
    fi
    
    log "[$disk] Znaleziono EFI na /dev/$efi_part"

    # 2. Wyodrębnij numer partycji (np. z sdb1 -> 1 lub nvme0n1p1 -> 1)
    if [[ "$efi_part" =~ ([0-9]+)$ ]]; then # np. sda1 -> 1
        part_num="${BASH_REMATCH[1]}"
    elif [[ "$efi_part" =~ p([0-9]+)$ ]]; then # np. nvme0n1p1 -> 1
         part_num="${BASH_REMATCH[1]}"
    fi

    if [[ -n "$part_num" ]]; then
        log "[$disk] Ustawiam kod typu (GUID) partycji $part_num na EFI (ef00) za pomocą sgdisk."
        # sgdisk ustawia atrybut partycji na "EFI System" (ef00) - jest nieinteraktywny
        sgdisk -t "$part_num":ef00 "/dev/$disk" 2>/dev/null || true
        
        # Używamy parted w trybie cichym (-s) aby ustawić flagę 'esp', ignorując błędy
        log "[$disk] Ustawiam flagę 'esp' na partycji $part_num za pomocą parted -s."
        parted -s "/dev/$disk" set "$part_num" esp on 2>/dev/null || true
        
        log "[$disk] Zakończono ustawianie atrybutów partycji $part_num."
    else
        log "[$disk] Nie można było wyodrębnić numeru partycji z '$efi_part'. Pomijam ustawianie flag."
    fi

    # 3. Kopiowanie Fallback Bootloader
    local mnt="/tmp/efi_${disk}_$$"
    mkdir -p "$mnt"
    if ! mount "/dev/$efi_part" "$mnt" 2>/dev/null; then
        log "[$disk] Nie można zamontować EFI /dev/$efi_part – pomijam instalację fallback."
        rmdir "$mnt"
        return 0
    fi

    # Upewnienie się, że jest fallback bootloader (bootx64.efi)
    if [[ -f "$mnt/EFI/Microsoft/Boot/bootmgfw.efi" ]]; then
        mkdir -p "$mnt/EFI/Boot"
        if [[ ! -f "$mnt/EFI/Boot/bootx64.efi" ]]; then
            cp "$mnt/EFI/Microsoft/Boot/bootmgfw.efi" "$mnt/EFI/Boot/bootx64.efi" 2>/dev/null
            log "[$disk] Fallback bootx64.efi ustawiony"
        else
            log "[$disk] Fallback bootx64.efi już istnieje"
        fi
    else
        log "[$disk] Brak bootmgfw.efi – to już temat na naprawę z WinPE"
    fi

    umount "$mnt"
    rmdir "$mnt"

    log "[$disk] SAFE zakończone"
}


# ============================================================================
# WERYFIKACJA
# ============================================================================

verify_disks() {
    local selected_image="$1"
    shift
    local target_disks=("$@")

    log "=== WERYFIKACJA (pierwsze ${VERIFY_MB}MB) ==="

    local decompress_cmd="cat"
    if [[ "$selected_image" == *.zst ]]; then
        decompress_cmd="zstd -dc"
    elif [[ "$selected_image" == *.gz ]]; then
        decompress_cmd="gzip -dc"
    fi

    local tmp_start="/tmp/img_start_$$.bin"
    log "Tworzę sumę kontrolną z obrazu..."
    $decompress_cmd "$selected_image" | dd of="$tmp_start" bs=1M count="$VERIFY_MB" iflag=fullblock status=none 2>/dev/null
    local img_start_sum
    img_start_sum=$(sha256sum "$tmp_start" | awk '{print $1}')
    rm -f "$tmp_start"
    
    log "Suma obrazu: $img_start_sum"

    for disk in "${target_disks[@]}"; do
        log "Weryfikuję /dev/$disk..."
        local disk_start_sum
        disk_start_sum=$(dd if="/dev/$disk" bs=1M count="$VERIFY_MB" iflag=fullblock status=none 2>/dev/null | sha256sum | awk '{print $1}')
        if [[ "$img_start_sum" == "$disk_start_sum" ]]; then
            log "[$disk] ✓ Checksum OK"
        else
            log "[$disk] ✗ Checksum NIEZGODNY (Suma dysku: $disk_start_sum)"
        fi
    done
}

# ============================================================================
# PRZYWRACANIE OBRAZU
# ============================================================================

restore_image() {
    log "=== PRZYWRACANIE OBRAZU ==="

    mkdir -p "$IMAGES_DIR"

    echo ""
    echo "Dostępne obrazy:"
    local images=()
    while IFS= read -r -d '' img; do
        images+=("$img")
    done < <(find "$IMAGES_DIR" -maxdepth 1 -type f \( -name "*.img" -o -name "*.img.zst" -o -name "*.img.gz" \) -print0 2>/dev/null | sort -z)

    if [[ ${#images[@]} -eq 0 ]]; then
        error_exit "Nie znaleziono obrazów w $IMAGES_DIR"
    fi

    local i=1
    for img in "${images[@]}"; do
        local size
        size=$(stat -c%s "$img" | numfmt --to=iec-i --suffix=B)
        printf "   %2d) %-50s %s\n" "$i" "$(basename "$img")" "$size"
        ((i++))
    done

    echo ""
    read -p "Który obraz? [1-${#images[@]}]: " img_choice
    img_choice=$(echo "$img_choice" | xargs)

    if ! [[ "$img_choice" =~ ^[0-9]+$ ]] || [[ $img_choice -lt 1 ]] || [[ $img_choice -gt ${#images[@]} ]]; then
        error_exit "Nieprawidłowy wybór"
    fi

    local selected_image="${images[$((img_choice-1))]}"
    log "Obraz: $selected_image"

    local system_disk
    system_disk="$(detect_system_disk)"

    echo ""
    echo "Dostępne dyski docelowe:"
    local available_targets
    available_targets=$(list_disks "$TARGET_DISK_PATTERNS" true "$system_disk")

    if [[ -z "$available_targets" ]]; then
        error_exit "Nie znaleziono dysków docelowych (Pamiętaj, że dysk systemowy '$system_disk' jest chroniony)"
    fi

    echo ""
    echo "Dostępne: $available_targets"
    echo ""
    echo "DYSK SYSTEMOWY ($system_disk) JEST CHRONIONY"
    echo ""
    read -p "Na które dyski? (np. sdb sdc lub 'all'): " target_input
    target_input=$(echo "$target_input" | xargs)

    local target_disks=()
    if [[ "$target_input" == "all" ]]; then
        target_disks=($available_targets)
    else
        for disk in $target_input; do
            disk=$(echo "$disk" | sed 's|^/dev/||')
            if [[ ! -b "/dev/$disk" ]]; then
                error_exit "Dysk /dev/$disk nie istnieje"
            fi
            if [[ "$disk" == "$system_disk" ]]; then
                error_exit "Nie można nadpisać dysku systemowego '$system_disk'"
            fi
            
            local found=0
            for allowed in $available_targets; do
                [[ "$disk" == "$allowed" ]] && found=1
            done
            [[ $found -eq 0 ]] && error_exit "Dysk /dev/$disk nie jest na liście dostępnych celów (być może to partycja?)"
            
            target_disks+=("$disk")
        done
    fi

    if [[ ${#target_disks[@]} -eq 0 ]]; then
        error_exit "Nie wybrano dysków"
    fi

    echo ""
    echo "System w obrazie:"
    echo "   1) Linux"
    echo "   2) Windows"
    read -p "Wybierz [1/2] (domyślnie: $DEFAULT_OS_PROFILE): " os_choice
    os_choice=$(echo "$os_choice" | xargs)

    local os_profile="$DEFAULT_OS_PROFILE"
    case "$os_choice" in
        1) os_profile="linux" ;;
        2) os_profile="windows" ;;
        "") os_profile="$DEFAULT_OS_PROFILE" ;;
    esac

    log "Profil: $os_profile"

    echo ""
    echo "========================================"
    echo "UWAGA: Nadpiszę dyski:"
    for disk in "${target_disks[@]}"; do
        local size
        size=$(lsblk -ndo SIZE "/dev/$disk" 2>/dev/null || echo "?")
        echo "   /dev/$disk ($size)"
    done
    echo "========================================"
    echo ""
    read -p "Potwierdzam [wpisz YES]: " confirm

    if [[ "$confirm" != "YES" ]]; then
        log "Anulowano"
        exit 0
    fi

    log "START klonowania"

    for disk in "${target_disks[@]}"; do
        log "Czyszczę /dev/$disk..."
        wipefs -a "/dev/$disk" 2>/dev/null || true
        if [[ "$FORCE_ZAP_TARGETS" == "yes" ]]; then
            log "Wymuszam ZAP (GPT/MBR) na /dev/$disk"
            sgdisk --zap-all "/dev/$disk" 2>/dev/null || true
        fi
        partprobe "/dev/$disk" 2>/dev/null || true
    done

    sleep 1

    echo ""
    echo "ZAPIS: $(date)"

    parallel_write_image "$selected_image" "${target_disks[@]}"

    sync
    sleep 2

    for disk in "${target_disks[@]}"; do
        partprobe "/dev/$disk" 2>/dev/null || true
        blockdev --rereadpt "/dev/$disk" 2>/dev/null || true
    done

    sleep 2
    udevadm settle --timeout=10 2>/dev/null || true

    for disk in "${target_disks[@]}"; do
        log "[$disk] Partycje:"
        lsblk -o NAME,SIZE,FSTYPE "/dev/$disk" 2>/dev/null | tail -n +2 | while read -r line; do
            log "[$disk]    $line"
        done
    done

    if [[ "$os_profile" == "windows" ]]; then
        
        ### NOWY KROK: ntfsfix ###
        log "Naprawiam flagi NTFS (aby pominąć chkdsk)..."
        for disk in "${target_disks[@]}"; do
            # Znajdź wszystkie partycje NTFS na tym dysku
            local ntfs_parts
            ntfs_parts=$(lsblk -ln -o NAME,FSTYPE "/dev/$disk" 2>/dev/null | grep -i 'ntfs' | awk '{print $1}' || true)
            
            for part in $ntfs_parts; do
                log "[$disk] Uruchamiam ntfsfix na /dev/$part"
                # -d czyści "dirty" flag, -b próbuje naprawić zepsute sektory boot
                ntfsfix -d -b "/dev/$part" 2>/dev/null || log "[$disk] ntfsfix na /dev/$part nie powiódł się (to może być OK)"
            done
        done
        ### KONIEC ntfsfix ###
        
        case "$WINDOWS_BOOT_FIX_MODE" in
            safe)
                for disk in "${target_disks[@]}"; do
                    fix_windows_boot_safe "$disk" || true
                done
                ;;
            none)
                log "Pominięto naprawę Windows (WINDOWS_BOOT_FIX_MODE=none)"
                ;;
            *)
                log "Tryb $WINDOWS_BOOT_FIX_MODE niezaimplementowany – użyj safe/none"
                ;;
        esac
    fi

    verify_disks "$selected_image" "${target_disks[@]}"

    log "=== ZAKOŃCZONO ==="

    echo ""
    echo "========================================"
    echo "                GOTOWE!"
    echo "========================================"
    echo ""
    echo "Nowe dyski są gotowe do uruchomienia."
    echo "Jeśli obraz był zrobiony po 'sysprep', uruchomi się kreator OOBE."
    echo ""

    echo "Naciśnij Enter..."
    read
}

# ============================================================================
# MENU
# ============================================================================

show_menu() {
    local system_disk
    system_disk="$(detect_system_disk)"
    clear
    echo "========================================"
    echo "      DiskImager v2.1 (FINAL)"
    echo "      Masowe klonowanie dysków"
    echo "========================================"
    echo ""
    echo "   1) Zrób obraz (Pamiętaj o SYSPEP!)"
    echo "   2) Przywróć obraz"
    echo "   3) Wyjście"
    echo ""
    echo "System: $system_disk (CHRONIONY)"
    echo "Obrazy: $IMAGES_DIR"
    echo "Windows boot fix: $WINDOWS_BOOT_FIX_MODE"
    echo ""
}

# ============================================================================
# MAIN
# ============================================================================

main() {
    check_root
    check_dependencies

    mkdir -p "$IMAGES_DIR"
    touch "$LOG_FILE"

    log "==== DiskImager v2.1 (FINAL) ===="

    while true; do
        show_menu
        read -p "Wybierz [1/2/3]: " choice

        case "$choice" in
            1) create_image ;;
            2) restore_image ;;
            3)
                log "Zakończono"
                exit 0
                ;;
            *)
                echo "Nieprawidłowy wybór"
                sleep 1
                ;;
        esac
    done
}

main "$@"
