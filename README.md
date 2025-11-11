# 💾 DiskImager - Narzędzie do Masowego Klonowania Dysków (Obraz 1:1)

**DiskImager.sh** to zaawansowany skrypt Bash stworzony do szybkiego i niezawodnego klonowania całych dysków twardych (HDD/SSD/NVMe) na wiele urządzeń docelowych jednocześnie, wykorzystując obraz 1:1. Jest to idealne rozwiązanie do masowej konfiguracji stacji roboczych, laboratoriów komputerowych czy serwerów.

Skrypt wykorzystuje **dd** oraz **pv** (Pipe Viewer) do klonowania, **zstd** lub **gzip** do kompresji w locie oraz narzędzia takie jak **sgdisk**, **parted** i **ntfsfix** do automatycznej naprawy partycji i bootloadera Windows (tryb UEFI/GPT).

## 🚀 Główne Funkcje

  * **Obraz 1:1 (Bit-for-Bit):** Klonowanie sektor po sektorze dla pełnej wierności kopii.
  * **Wysoka Wydajność:** **Równoległe zapisywanie** obrazu na wiele dysków docelowych przy użyciu potoków FIFO, drastycznie skracając czas klonowania masowego.
  * **Kompresja w Locie:** Obsługa kompresji **zstd** (zalecana) i **gzip** podczas tworzenia obrazu.
  * **Ochrona Dysku Systemowego:** Automatyczne wykrywanie i ochrona dysku, z którego działa system operacyjny klonujący (np. Linux Live USB).
  * **Automatyczna Naprawa Windows (UEFI):** Opcjonalny tryb `safe` do naprawy:
      * Ustawienie flag `esp`/`ef00` dla partycji EFI (GPT).
      * Instalacja fallback bootloadera (`bootx64.efi`).
      * Oczyszczanie flagi "dirty" na partycjach NTFS za pomocą `ntfsfix` (aby pominąć `chkdsk` przy pierwszym uruchomieniu).
  * **Weryfikacja:** Szybka weryfikacja integralności danych poprzez porównanie sumy kontrolnej pierwszych $100\text{MB}$ dysku docelowego z obrazem źródłowym.

-----

## 🛠️ Wymagania i Instalacja

Skrypt musi być uruchomiony z uprawnieniami **root** na dystrybucji Linuksa (np. Ubuntu Live, GParted Live).

### Niezbędne Narzędzia (Pakiety)

Upewnij się, że masz zainstalowane następujące narzędzia:

  * `pv` (pipe viewer)
  * `dd`, `lsblk`, `blockdev`, `findmnt` (zazwyczaj standard)
  * `gptfdisk` (pakiet zawierający `sgdisk`)
  * `parted`, `partprobe`
  * `ntfs-3g` (pakiet zawierający `ntfsfix`)
  * `zstd` (jeśli używasz kompresji Zstandard)

Na systemach Debian/Ubuntu możesz je zainstalować tak:

```bash
sudo apt update
sudo apt install pv gptfdisk util-linux ntfs-3g zstd
```

-----

## ⚙️ Konfiguracja

Przed uruchomieniem dostosuj zmienne w sekcji `KONFIGURACJA` w pliku `diskimager.sh`.

| Zmienna | Opis | Domyślna wartość |
| :--- | :--- | :--- |
| `IMAGES_DIR` | Ścieżka, gdzie będą przechowywane obrazy. Musi to być **szybki dysk** z dużą ilością miejsca. | `/mnt/ssd/disk-images` |
| `COMPRESS` | Typ kompresji podczas tworzenia obrazu: `none` | `gz` | **`zst`** (zalecany). | `none` |
| `DD_BS` | Rozmiar bloku dla `dd`/`pv`. `4M` jest optymalne dla SSD/NVMe. | `4M` |
| `WINDOWS_BOOT_FIX_MODE`| Tryb naprawy Windows boot: **`safe`** (zalecany) lub `none`. | `safe` |
| `VERIFY_MB` | Ilość danych (MB) sprawdzana na początku dysku po klonowaniu w celu szybkiej weryfikacji. | `100` |

-----

## 📝 Instrukcja Użycia

### 1\. Uruchomienie

Otwórz terminal w katalogu, gdzie znajduje się skrypt, i uruchom go:

```bash
sudo ./diskimager.sh
```

### 2\. Tworzenie Obrazu (Opcja 1) 💾

Ten tryb służy do sklonowania dysku źródłowego do pliku obrazu.

1.  Wybierz opcję **1** (`Zrób obraz`).
2.  **Wybór Źródła:** Podaj nazwę dysku, z którego chcesz zrobić obraz (np. `sdb`).
    > ⚠️ **Ważne (Windows):** Obraz Windows musi być wykonany **po uruchomieniu Sysprep** (`OOBE`, `Generalize`, `Shutdown`), aby działał poprawnie na maszynach docelowych.
3.  **Etykieta:** Podaj opisową etykietę (np. `W11-Master-2025`).
4.  **Klonowanie:** Rozpocznie się tworzenie obrazu z postępem widocznym dzięki `pv`. Plik zostanie zapisany w `$IMAGES_DIR`.

### 3\. Przywracanie Obrazu (Opcja 2) 🔄

Ten tryb służy do zapisania obrazu na jeden lub wiele dysków docelowych.

1.  Wybierz opcję **2** (`Przywróć obraz`).
2.  **Wybór Obrazu:** Wybierz numer z listy dostępnych obrazów.
3.  **Wybór Celów:** Skrypt wyświetli listę **dostępnych** dysków docelowych (pamiętaj, dysk systemowy jest chroniony).
      * Podaj nazwy dysków docelowych oddzielone spacją (np. `sdb sdc sdd`).
      * Wpisz **`all`**, aby wybrać wszystkie dostępne cele z listy.
4.  **Profil OS:** Wybierz profil systemu operacyjnego w obrazie (`1) Linux` lub `2) Windows`).
5.  **Potwierdzenie:** Potwierdź operację, wpisując słowo **`YES`**.
6.  **Klonowanie Równoległe:** Rozpocznie się zapis obrazu **jednocześnie** na wszystkie wybrane dyski docelowe.
7.  **Faza Końcowa (Naprawa Windows):** Jeśli wybrano profil **Windows**, skrypt:
      * Użyje **`ntfsfix`** do usunięcia flagi "dirty" NTFS.
      * Uruchomi funkcję **`fix_windows_boot_safe`** (ustawienie flag EFI/ESP i instalacja fallback bootloadera).
8.  **Weryfikacja:** Przeprowadzona zostanie szybka weryfikacja sumy kontrolnej na początku każdego dysku docelowego.

Po zakończeniu dyski są gotowe do uruchomienia. Pełny zapis operacji znajdziesz w pliku `$LOG_FILE`.

-----

## 📄 Licencja

Projekt objęty jest licencją **MIT**. Szczegóły w pliku `LICENSE`.

```
```
