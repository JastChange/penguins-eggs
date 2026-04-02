/**
 * ./src/krill/modules/partition.d/bios-standard.ts (versione unificata)
 * penguins-eggs v.25.7.x / ecmascript 2020
 * author: Piero Proietti
 * email: piero.proietti@gmail.com
 * license: MIT
 * Partiziona un disco per sistemi BIOS, gestendo dinamicamente ext4 (con swap) e btrfs (senza swap).
 */

import { exec } from '../../../../lib/utils.js'
import Sequence from '../../sequence.js'

/**
 * @param this
 * @param installDevice
 * @param p
 * @returns
 */
export default async function biosStandard(this: Sequence, installDevice = '', p = ''): Promise<boolean> {
  const fsType = this.partitions.filesystemType

  // 1. Creazione della tabella delle partizioni (comune a entrambi)
  await exec(`parted --script ${installDevice} mklabel msdos`, this.echo)

  // 2. Logica di partizionamento condizionale
  if (fsType === 'btrfs') {
    // --- CASO BTRFS: NESSUNA PARTIZIONE DI SWAP ---
    // Creiamo un'unica partizione che occupa tutto il disco.
    // Lo swap verrà gestito con uno swapfile direttamente su Btrfs.
    await exec(`parted --script --align optimal ${installDevice} mkpart primary "" 1MiB 100%`, this.echo) // Partizione 1: root
    await exec(`parted ${installDevice} set 1 boot on`, this.echo)

    // Imposta i dispositivi per Btrfs
    this.devices.root.name = `${installDevice}${p}1`
    this.devices.swap.name = 'none' // Nessuna partizione di swap
    this.devices.boot.name = 'none'
  } else {
    // --- CASO EXT4: /boot (4GB) + / (rest), NO SWAP ---
    // Partition 1: /boot  1MiB -> 4097MiB (4GB, boot flag)
    await exec(`parted --script --align optimal ${installDevice} mkpart primary ext4 1MiB 4097MiB`, this.echo)
    await exec(`parted ${installDevice} set 1 boot on`, this.echo)
    // Partition 2: /  4097MiB -> 100%
    await exec(`parted --script --align optimal ${installDevice} mkpart primary "" 4097MiB 100%`, this.echo)

    // Dedicated /boot partition (4GB)
    this.devices.boot.name = `${installDevice}${p}1`
    this.devices.boot.fsType = 'ext4'
    this.devices.boot.mountPoint = '/boot'

    // No swap partition
    this.devices.swap.name = 'none'

    this.devices.root.name = `${installDevice}${p}2`
  }

  // 3. Impostazioni finali comuni
  this.devices.root.fsType = fsType
  this.devices.root.mountPoint = '/'

  // DATA/EFI non sono usati in questo schema
  this.devices.data.name = 'none'
  this.devices.efi.name = 'none'

  return true
}
