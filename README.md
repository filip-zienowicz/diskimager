# 💾 DiskImager - Narzędzie do Masowego Klonowania Dysków (Obraz 1:1)

**DiskImager.sh** to zaawansowany skrypt Bash stworzony do szybkiego i niezawodnego klonowania całych dysków twardych (HDD/SSD/NVMe) na wiele urządzeń docelowych jednocześnie, wykorzystując obraz 1:1. Jest to idealne rozwiązanie do masowej konfiguracji stacji roboczych, laboratoriów komputerowych czy serwerów.

Skrypt wykorzystuje **dd** oraz **pv** (Pipe Viewer) do klonowania, **zstd** lub **gzip** do kompresji w locie oraz narzędzia takie jak **sgdisk** i **parted** do automatycznej naprawy partycji i bootloadera Windows (tryb UEFI/GPT).

## Główne Funkcje

* **Obraz 1:1 (Bit-for-Bit):** Klonowanie sektor po sektorze.
* **Wysoka Wydajność:** Równoległe zapisywanie obrazu na wiele dysków docelowych przy użyciu potoków FIFO.
* **Kompresja w Locie:** Obsługa kompresji **zstd** (zalecana) i **gzip** podczas tworzenia obrazu.
* **Ochrona Dysku Systemowego:** Automatyczne wykrywanie i ochrona dysku, z którego działa system operacyjny klonujący (LiveCD/LiveUSB).
* **Automatyczna Naprawa Windows (UEFI):** Opcjonalny tryb `safe` do naprawy partycji EFI (ustawienie flag `esp`/`ef00`) i instalacja fallback bootloadera (`bootx64.efi`).
* **Oczyszczanie NTFS:** Użycie `ntfsfix` do usuwania flagi "dirty" (aby pominąć `chkdsk` przy pierwszym uruchomieniu Windows).
* **Weryfikacja:** Szybka weryfikacja sumy kontrolnej pierwszych MB po klonowaniu.

## 🚀 Wymagania

Skrypt musi być uruchomiony z uprawnieniami **root** (np. za pomocą `sudo` lub bezpośrednio jako root) na dystrybucji Linuksa (np. Ubuntu Live, Parted Magic, Clonezilla Live – najlepiej minimalistyczny Debian/Ubuntu).

### Niezbędne Narzędzia (Pakiety)

Upewnij się, że masz zainstalowane następujące narzędzia:

* `pv` (pipe viewer)
* `dd`
* `lsblk`, `wipefs`, `sgdisk`, `partprobe`, `blkid`, `parted`, `blockdev`, `findmnt` (zazwyczaj część `util-linux` i `gptfdisk`)
* `ntfsfix` (część pakietu **`ntfs-3g`**)
* `zstd` (jeśli używasz kompresji Zstandard)
* `gzip` (jeśli używasz kompresji Gzip)

Na systemach Debian/Ubuntu możesz je zainstalować np. tak:

```bash
sudo apt update
sudo apt install pv gptfdisk util-linux ntfs-3g zstd
