# Script para crear carpetas y archivos de relleno para Kindle en modo MTP
# Crea carpetas 8, 16, 32, 64 con archivos de 1GB, 100MB y 10MB, y los comprime en un zip
import os
import zipfile

BASE = os.path.join(os.path.dirname(__file__), 'MTP')
SIZES_GB = [8, 16, 32, 64]
FILE_SPECS = [
    (1 * 1024**3, '1gb'),    # 1GB
    (100 * 1024**2, '100mb'),# 100MB
    (10 * 1024**2, '10mb'),  # 10MB
]
FILES_PER_SIZE = 1  # Puedes ajustar si quieres más archivos por tamaño

def ensure_dir(path):
    if not os.path.exists(path):
        os.makedirs(path)

def create_dummy_file(path, size):
    # Crea un archivo de tamaño 'size' en bytes, sin llenarlo de ceros (sólo reserva espacio)
    with open(path, 'wb') as f:
        f.seek(size-1)
        f.write(b'\0')

def main():
    for gb in SIZES_GB:

        folder = os.path.join(BASE, str(gb))
        ensure_dir(folder)
        total_bytes = gb * 1024**3


        # Lógica: (GB - 1) archivos de 1GB, 9 archivos de 100MB, 10 archivos de 10MB
        file_idx_1gb = 1
        for _ in range(gb - 1):
            fname = f"fill_{gb}gb_1gb_{file_idx_1gb}"
            fpath = os.path.join(folder, fname)
            print(f"Creando {fpath} (1GB)...")
            create_dummy_file(fpath, 1 * 1024**3)
            file_idx_1gb += 1

        file_idx_100mb = 1
        for _ in range(9):
            fname = f"fill_{gb}gb_100mb_{file_idx_100mb}"
            fpath = os.path.join(folder, fname)
            print(f"Creando {fpath} (100MB)...")
            create_dummy_file(fpath, 100 * 1024**2)
            file_idx_100mb += 1

        file_idx_10mb = 1
        for _ in range(10):
            fname = f"fill_{gb}gb_10mb_{file_idx_10mb}"
            fpath = os.path.join(folder, fname)
            print(f"Creando {fpath} (10MB)...")
            create_dummy_file(fpath, 10 * 1024**2)
            file_idx_10mb += 1

        # Comprimir carpeta
        zipname = os.path.join(BASE, f"fill_{gb}gb.zip")
        print(f"Comprimiendo {folder} en {zipname} ...")
        with zipfile.ZipFile(zipname, 'w', zipfile.ZIP_DEFLATED) as zipf:
            for root, _, files in os.walk(folder):
                for file in files:
                    arcname = os.path.relpath(os.path.join(root, file), BASE)
                    zipf.write(os.path.join(root, file), arcname)
        print(f"Listo: {zipname}")

if __name__ == '__main__':
    main()