echo "Stop early-loading the NVIDIA driver on hybrid GPU systems so hibernation can resume"

# install/hardware/nvidia.sh used to write nvidia.conf on every NVIDIA machine.
# On a hybrid laptop the iGPU provides early KMS, and having nvidia already
# loaded inside the initramfs makes resume from hibernation fail with
# "nv_pmops_freeze returns -5" / "PM: hibernation: resume failed (-5)".
# Drop the drop-in on those machines and rebuild the initramfs once. A marker
# records completion so another user's run does not repeat the rebuild.

nvidia_conf="${OMARCHY_MKINITCPIO_NVIDIA_CONF:-/etc/mkinitcpio.conf.d/nvidia.conf}"
rebuild_marker="${OMARCHY_NVIDIA_REBUILD_MARKER:-/var/lib/omarchy/migrations/1787683023}"

omarchy-cmd-present limine-mkinitcpio || exit 0
[[ -f $nvidia_conf ]] || exit 0
[[ ! -e $rebuild_marker ]] || exit 0
omarchy-hw-nvidia-only-display && exit 0

echo "This is a hybrid GPU machine; removing nvidia from the initramfs and rebuilding it"

# The drop-in has to be gone before the rebuild, but the rebuild is what makes
# the change real. If it fails, put the drop-in back so the next run finds it
# and retries instead of exiting at the check above with a stale image.
backup=$(mktemp)
cp "$nvidia_conf" "$backup"
sudo rm -f "$nvidia_conf"
if ! sudo limine-mkinitcpio; then
  sudo install -m644 "$backup" "$nvidia_conf"
  rm -f "$backup"
  echo "Rebuilding the initramfs failed; restored $nvidia_conf so the migration retries" >&2
  exit 1
fi

# limine-mkinitcpio can return success after skipping a failed kernel build.
# The previous image still contains the NVIDIA modules, and with the drop-in
# gone the next run would exit successfully and never try again. Restore the
# drop-in unless every current UKI omits those modules.
uki_dir="${OMARCHY_BOOT_UKI_DIR:-/boot/EFI/Linux}"
mapfile -d '' images < <(sudo find "$uki_dir" -maxdepth 1 -name 'omarchy_linux*.efi' -print0 2>/dev/null | sort -z)
image_ok=0
if ((${#images[@]} > 0)); then
  image_ok=1
  image=""
  for image in "${images[@]}"; do
    [[ -n $image ]] || continue
    listing=$(sudo lsinitcpio "$image") || {
      image_ok=0
      break
    }
    if grep -E '/nvidia(_modeset|_uvm|_drm|_peermem)?\.ko' <<<"$listing" >/dev/null; then
      image_ok=0
      break
    fi
  done
fi
if ((image_ok == 0)); then
  sudo install -m644 "$backup" "$nvidia_conf"
  rm -f "$backup"
  echo "Boot image still contains the NVIDIA driver, or none was found; restored $nvidia_conf so the migration retries" >&2
  exit 1
fi

rm -f "$backup"
sudo install -Dm644 /dev/null "$rebuild_marker"
