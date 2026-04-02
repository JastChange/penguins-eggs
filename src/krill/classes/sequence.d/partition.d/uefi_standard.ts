/**
 * ./src/krill/modules/partition.d/uefi-standard.ts
 * penguins-eggs v.25.7.x / ecmascript 2020
 * author: Piero Proietti
 * email: piero.proietti@gmail.com
 * license: MIT
 * https://stackoverflow.com/questions/23876782/how-do-i-split-a-typescript-class-into-multiple-files
 */

import { exec } from '../../../../lib/utils.js'
import Sequence from '../../sequence.js'

export default async function uefiStandard(this: Sequence, installDevice = '', p = ''): Promise<boolean> {
  await exec(`parted --script ${installDevice} mklabel gpt`, this.echo)

  // Partition 1: EFI  1MiB -> 257MiB (256MB)
  await exec(`parted --script ${installDevice} mkpart efi fat32 1MiB 257MiB`, this.echo)
  // Partition 2: /boot  257MiB -> 4353MiB (4GB)
  await exec(`parted --script ${installDevice} mkpart boot ext4 257MiB 4353MiB`, this.echo)
  // Partition 3: /  4353MiB -> 100%
  await exec(`parted --script ${installDevice} mkpart root ext4 4353MiB 100%`, this.echo)

  await exec(`parted --script ${installDevice} set 1 boot on`, this.echo)
  await exec(`parted --script ${installDevice} set 1 esp on`, this.echo)

  this.devices.efi.name = `${installDevice}${p}1`
  this.devices.efi.fsType = 'F 32 -I'
  this.devices.efi.mountPoint = '/boot/efi'

  // Dedicated /boot partition (4GB)
  this.devices.boot.name = `${installDevice}${p}2`
  this.devices.boot.fsType = 'ext4'
  this.devices.boot.mountPoint = '/boot'

  this.devices.root.name = `${installDevice}${p}3`
  this.devices.root.fsType = 'ext4'
  this.devices.root.mountPoint = '/'

  // No swap partition
  this.devices.swap.name = 'none'
  this.devices.data.name = 'none'

  return true
}
