#! /bin/sh
#
# Requires: qemu-img ovftool

formats_via_qemu_img_convert="vhdx raw qcow2"	# raw qcow2 vhdx supported.
test -z "$DEBUG" && DEBUG=true
imageName=$(basename $1 .ovf)

if [ -z "$(qemu-img --help | grep 'qemu-img version')" ]; then
  echo "ERROR: qemu-img is required!"
  exit 0
fi
qemu-img --help | grep 'qemu-img version'

if  [ ! -f /usr/bin/ovftool ]; then
  echo "Warning: Cannot generate vmx. Please install VMware OVF Tool"
  echo "See https://developercenter.vmware.com/tool/ovf/"
  echo ""
  echo "Press ENTER to continue without VMX or OVA support, CTRL-C to stop."
  read a
fi
ovftool --version

$DEBUG && set -x

if  [ -f /usr/bin/ovftool ]; then
  mkdir -p vmx
  echo "Error messages expected from ovftool. 'Unsupported hardware family virtualbox-2.2', 'No support for the virtual hardware device type 20'."
  echo "You can ignore them. They do apparently no harm."
  ovftool --lax $imageName.ovf vmx/$imageName.vmx || exit 1
  # Line 25: Unsupported hardware family 'virtualbox-2.2'
  # Line 48: OVF hardware element 'ResourceType' with instance ID '3': No support for the virtual hardware device type '20'.
  zip $imageName.vmx.zip vmx/*
  rm -rf vmx

  ## Error: This generates ova's that do not load in VirtualBox.
  ## Error message: Could not verify the contents of $imageName.mf against 
  ## the available files (VERR_MANIFEST_UNSUPPORTED_DIGEST_TYPE)
  # ovftool --shaAlgorithm=sha256 --lax $imageName.ovf $imageName.ova
  # ovftool --shaAlgorithm=sha1 --lax $imageName.ovf $imageName.ova

  ovftool --skipManifestGeneration --lax $imageName.ovf $imageName.ova
  ## instead of let ovftool create a manifest, do it manually:
  # echo "SHA1($imageName-disk1.vmdk)= $(sha1sum $imageName-disk1.vmdk|sed -e 's/ .*//')" > $imageName.mf
  # echo "SHA1($imageName.ovf)= $(sha1sum $imageName.ovf|sed -e 's/ .*//')" >> $imageName.mf
  zip $imageName.ova.zip $imageName.ova
  rm $imageName.ova
fi

bin_dir=$(dirname $0)

# qemu-img 1.6.2 needs the patch, qemu-img 2.3.0 does not.
qemu-img --help | grep -q 'qemu-img version 1' && needpatching=true || needpatching=false
$needpatching && $bin_dir/patchvmdk.sh $imageName-disk1.vmdk 02

## convert to other formats...
for fmt in $formats_via_qemu_img_convert; do
 # vhdx needs 40GB space, qemu-img exits with code 1, if out of space.
 qemu-img convert -p -f vmdk $imageName-disk1.vmdk -O $fmt $imageName.$fmt || exit 1

 # Zip if you want but the difference is not so big (except for vmdx):
 zip $imageName.$fmt.zip $imageName.$fmt || exit 1
 rm $imageName.$fmt
done
$needpatching && $bin_dir/patchvmdk.sh $imageName-disk1.vmdk 03

### sneak preview:
# sudo mount -o loop,ro,offset=$(expr 512 \* 2048) $imageName.raw /mnt


zip $imageName.vmdk.zip $imageName-*.vmdk
$DEBUG || rm $imageName-*.vmdk



