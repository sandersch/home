#!/usr/bin/env bash
# Install attended tooling only. No timers, fstab entries, or alert activation.
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
[[ "$EUID" -eq 0 ]] || { echo 'Run with sudo on minis' >&2; exit 1; }
[[ "$(hostname -s)" = minis ]] || { echo 'Installer is for minis' >&2; exit 1; }
for tool in python3 findmnt lsblk wipefs sfdisk mkfs.ext4 chattr lsattr ionice nice cryptsetup \
            mount mountpoint umount swapon udevadm sync du \
            podman; do
  command -v "$tool" >/dev/null
done
python3 -c 'import yaml'
install -d -o root -g root -m 0755 /usr/local/lib/offline-ssd
python3 "$root/runbooks/backups/workstation-install-restic.py" --directory /usr/local/lib/offline-ssd
for file in offline-ssd.py offline-contracts.py legacy-rsnapshot.py; do
  install -o root -g root -m 0755 "$root/runbooks/backups/$file" /usr/local/lib/offline-ssd/
done
install -d -o root -g root -m 0755 /usr/local/lib/offline-ssd/contracts
install -o root -g root -m 0644 "$root"/infrastructure/monitoring/contracts/vault-* \
  /usr/local/lib/offline-ssd/contracts/
python3 - "$root" <<'PY'
import json
from pathlib import Path
import sys
import yaml
source = Path(sys.argv[1]) / 'infrastructure/monitoring/restic-nas-config.yaml'
config = yaml.safe_load(source.read_text())['data']
path = Path('/usr/local/lib/offline-ssd/appstate-contract.json')
path.write_text(json.dumps({'version': config['BACKUP_CONTRACT_VERSION'],
                            'required': config['REQUIRED_SQLITE_DATABASES'].strip().splitlines()}) + '\n')
path.chmod(0o644)
PY
# RomM verification imports with the exact image production runs. Pull it now so
# attended operations never need registry access (they run with --pull=never).
romm_image="$(python3 - "$root" <<'PY'
import importlib.util
import json
from pathlib import Path
import sys
root = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location('contracts', root / 'runbooks/backups/offline-contracts.py')
contracts = importlib.util.module_from_spec(spec)
spec.loader.exec_module(contracts)
image = contracts.romm_mariadb_image((root / 'apps/media/romm/deployment.yaml').read_text())
path = Path('/usr/local/lib/offline-ssd/romm-mariadb.json')
path.write_text(json.dumps(image) + '\n')
path.chmod(0o644)
print(image['image'])
PY
)"
podman pull --quiet "$romm_image" >/dev/null
podman image exists "$romm_image"
install -d -o root -g root -m 0700 /mnt/offline
for drive in A B; do
  path="/mnt/offline/$drive"
  [[ ! -L "$path" ]] || { echo 'Symlink mountpoint refused' >&2; exit 1; }
  ! mountpoint -q "$path" || { echo 'SSD already mounted; finish operation first' >&2; exit 1; }
  if [[ -d "$path" ]]; then
    [[ -z "$(find "$path" -mindepth 1 -maxdepth 1 -print -quit)" ]] || exit 1
  else
    install -d -o root -g root -m 0555 "$path"
  fi
  chattr +i "$path"
done
ln -sfn /usr/local/lib/offline-ssd/offline-ssd.py /usr/local/sbin/offline-ssd
printf '%s\n' 'Installed. No SSD has been provisioned or enrolled. Follow offline-ssd.md.'
