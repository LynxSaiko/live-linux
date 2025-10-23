#!/bin/bash
# [*] Author: LynxSaiko (Diperbaiki & Dioptimalkan oleh Gemini)
# [*] Deskripsi: Membuat Live ISO dari sistem LFS dengan dukungan Grafis dan konfigurasi DWM.

set -eu  # Keluar segera jika perintah gagal atau variabel tidak disetel

# --- KONFIGURASI PENGGUNA ---
LIVE_NAME="leakos"
LFS_SOURCE_ROOT="/"
# Partisi yang akan dicari oleh script 'init' saat booting.
LIVE_BUILD_DIR=$(find /mnt/liveiso/ -type d -name "${LIVE_NAME}-build*" | head -n1)
LIVE_PARTITION_DEV="/dev/sdb1"
ISO_OUTPUT_DIR="/mnt/liveiso"
ISO_NAME="${LIVE_NAME}-$(date +%Y%m%d).iso"
SQUASHFS_FILE="rootfs.squashfs"

# --- TENTUKAN KERJA ---
WORKDIR="${LIVE_BUILD_DIR}"
FINAL_ISO_PATH="${ISO_OUTPUT_DIR}/${ISO_NAME}"
KERNEL_VERSION=$(uname -r)

# Cek Tools
REQUIRED_TOOLS="mksquashfs xorriso rsync cpio gzip uname ldd modprobe"
echo "[+] Memeriksa tools yang diperlukan..."
for tool in $REQUIRED_TOOLS; do
    if ! command -v $tool &> /dev/null; then
        echo "[!] ERROR: '$tool' tidak ditemukan. Harap instal."
        exit 1
    fi
done

# FUNGSI CLEANUP DIHAPUS. DIREKTORI KERJA AKAN TETAP ADA SETELAH SCRIPT SELESAI.
# trap cleanup EXIT JUGA DIHAPUS.

# ==========================
# PERSIAPAN DAN COPY ROOTFS
# ==========================
echo "[+] Menyiapkan struktur direktori ISO di $WORKDIR..."
mkdir -pv "$WORKDIR"/{iso/boot/grub,rootfs,initrd_source}
mkdir -pv "$ISO_OUTPUT_DIR"

echo "---"
echo "[+] Menyalin root filesystem ke $WORKDIR/rootfs..."

# Daftar exclude. Direktori /home TIDAK dikecualikan untuk menyertakan DWM.
EXCLUDES=(
    "/proc" "/sys" "/dev" "/mnt" "/media" "/tmp" "/lost-found" "/run"
    "/var/log" "/var/cache" "/var/tmp" "/var/run" "/var/lock"
    "/.cache" "/usr/share/doc" "/usr/share/man"
    "$WORKDIR"
)

RSYNC_EXCLUDES=""
for ex in "${EXCLUDES[@]}"; do
    RSYNC_EXCLUDES+=" --exclude=$ex"
done

# Jalankan rsync. Ini akan menyalin /home/leakos/.dwm ke $WORKDIR/rootfs/home/leakos/.dwm
eval rsync -aAXv "$LFS_SOURCE_ROOT" "$WORKDIR/rootfs" $RSYNC_EXCLUDES

echo "[+] Membuat $SQUASHFS_FILE dari rootfs..."
mksquashfs "$WORKDIR/rootfs" "$WORKDIR/iso/boot/$SQUASHFS_FILE" -comp xz -b 256K

# ==========================
# MENYIAPKAN INITRAMFS (INITRD)
# ==========================
echo "---"
echo "[+] Menyiapkan Initramfs dan dependensi..."
INITRD_ROOT="$WORKDIR/initrd_source"
mkdir -pv "$INITRD_ROOT"/{bin,sbin,proc,sys,dev,tmp,newroot,lib,lib64,usr/lib,usr/sbin}

# Fungsi untuk mengumpulkan dependensi (ldd)
collect_dependencies() {
    local BINARY_PATH=$1
    local TARGET_DIR=$2

    ldd "$BINARY_PATH" 2>/dev/null | awk '
        /=>/ { print $3 }
        !/not a dynamic executable/ && !/=>/ { print $1 }
    ' | while read -r lib; do
        if [[ -f "$lib" ]]; then
            TARGET_LIB_DIR="${TARGET_DIR}${lib%/*}"
            mkdir -p "$TARGET_LIB_DIR"
            cp -v "$lib" "$TARGET_LIB_DIR/"
        fi
    done
}

# Biner inti yang diperlukan untuk boot, mount, dan modul kernel
CORE_BINS="/bin/sh /bin/ls /bin/cat /bin/echo /bin/mkdir /bin/mknod /bin/mount /bin/umount /sbin/switch_root /sbin/modprobe /sbin/udevadm"
for bin in $CORE_BINS; do
    if [ -f "$bin" ]; then
        cp -v "$bin" "$INITRD_ROOT/${bin#/}"
        collect_dependencies "$bin" "$INITRD_ROOT"
    fi
done
chmod +x "$INITRD_ROOT"/bin/* "$INITRD_ROOT"/sbin/*

# Salin modul kernel yang diperlukan ke Initrd (minimal)
echo "[+] Menyalin modul kernel dasar..."
MODULES_TO_COPY="kernel/fs kernel/lib kernel/drivers/block kernel/drivers/ata kernel/drivers/scsi kernel/drivers/usb kernel/drivers/gpu/drm"
mkdir -p "$INITRD_ROOT/lib/modules/$KERNEL_VERSION"
for mod_path in $MODULES_TO_COPY; do
    cp -Rv /lib/modules/$KERNEL_VERSION/$mod_path "$INITRD_ROOT/lib/modules/$KERNEL_VERSION/"
done
depmod -b "$INITRD_ROOT" "$KERNEL_VERSION" # Update dependency modules di initrd

# ==========================
# BUAT SCRIPT INIT
# ==========================
echo "[+] Membuat skrip init..."

# Modul grafis umum (misalnya, untuk KMS/modesetting)
GRAPHICS_MODULES="i915 amdgpu nouveau"

cat > "$INITRD_ROOT/init" << EOF
#!/bin/sh

export PATH=/bin:/sbin:/usr/bin:/usr/local/bin
SQUASHFS_FILE="$SQUASHFS_FILE"
LIVE_DEV="$LIVE_PARTITION_DEV"
LIVE_MOUNT_POINT="/livemount"

echo "=== Booting LFS LiveCD ==="

# Mount filesystems dasar
mount -t proc proc /proc
mount -t sysfs sys /sys
mount -t devtmpfs dev /dev

# Initialize udev/mdev untuk device node
/sbin/udevadm trigger
/sbin/udevadm settle

# Muat modul kernel yang diperlukan (termasuk potensi driver grafis)
for mod in $GRAPHICS_MODULES; do
    echo "Memuat \$mod..."
    /sbin/modprobe \$mod 2>/dev/null
done

mkdir -p \$LIVE_MOUNT_POINT

echo "Mounting device: \$LIVE_DEV..."
if mount -o ro \$LIVE_DEV \$LIVE_MOUNT_POINT; then
    
    SQUASHFS_PATH="\$LIVE_MOUNT_POINT/boot/\$SQUASHFS_FILE"
    if [ -f "\$SQUASHFS_PATH" ]; then
        
        if mount -t squashfs -o ro,loop "\$SQUASHFS_PATH" /newroot; then
            echo "✓ Root filesystem berhasil di-mount. Beralih ke sistem LiveOS..."
            
            # Cleanup
            umount \$LIVE_MOUNT_POINT
            umount /sys
            umount /proc
            umount /dev

            exec switch_root /newroot /sbin/init
        else
            echo "✗ Gagal mount SquashFS."
        fi
    else
        echo "✗ SquashFS tidak ditemukan di: \$SQUASHFS_PATH"
    fi
    umount \$LIVE_MOUNT_POINT
else
    echo "✗ Gagal mount \$LIVE_DEV."
fi

# Fallback
echo "=== Emergency Shell ==="
exec /bin/sh
EOF

chmod +x "$INITRD_ROOT/init"

# ==========================
# PEMBUATAN ISO
# ==========================
echo "---"
echo "[+] Membuat initramfs archive (initrd.img)..."
cd "$WORKDIR/initrd_source"
find . -print0 | cpio --null -ov --format=newc | gzip -9 > "$WORKDIR/iso/boot/initrd.img"

echo "[+] Menyalin kernel dan menyiapkan GRUB..."
cp -v "/boot/vmlinuz" "$WORKDIR/iso/boot/vmlinuz"

# Konfigurasi GRUB
cat > "$WORKDIR/iso/boot/grub/grub.cfg" << EOF
set timeout=5
set default=0
menuentry "$LIVE_NAME Live (Sistem Grafis DWM)" {
    linux /boot/vmlinuz
    initrd /boot/initrd.img
}
EOF

echo "[+] Membuat ISO Hybrid: $FINAL_ISO_PATH..."

MBR_BOOT_IMG="/usr/lib/grub/i386-pc/boot_hybrid.img"
# Cek path MBR boot image
if [ ! -f "$MBR_BOOT_IMG" ]; then
    echo "[!] PERINGATAN: Boot image MBR tidak ditemukan di path default. Mencoba path alternatif."
    MBR_BOOT_IMG=$(find /usr/lib/grub -name 'boot_hybrid.img' -print -quit 2>/dev/null)
fi

if [ -n "$MBR_BOOT_IMG" ] && [ -f "$MBR_BOOT_IMG" ]; then
    xorriso -as mkisofs \
        -iso-level 3 \
        -volid "${LIVE_NAME}_ISO" \
        -graft-points \
        -boot-load-size 4 \
        -boot-info-table \
        -b boot/grub/grub.cfg \
        -no-emul-boot \
        -isohybrid-mbr "$MBR_BOOT_IMG" \
        -output "$FINAL_ISO_PATH" \
        "$WORKDIR/iso"
else
     echo "[!] ERROR: Gagal menemukan boot image GRUB MBR. Membuat ISO standar tanpa Hybrid MBR."
     xorriso -as mkisofs \
        -iso-level 3 \
        -volid "${LIVE_NAME}_ISO" \
        -graft-points \
        -b boot/grub/grub.cfg \
        -output "$FINAL_ISO_PATH" \
        "$WORKDIR/iso"
fi

echo "=========================================================="
echo "[✓] ISO selesai dibuat: $FINAL_ISO_PATH"
echo "[i] Direktori kerja tetap dipertahankan: $WORKDIR"
echo "[i] Konfigurasi DWM Anda di /home/leakos/.dwm telah disertakan."
echo "[i] Pastikan /etc/inittab Anda telah disetel untuk meluncurkan Display Manager."
echo "=========================================================="
