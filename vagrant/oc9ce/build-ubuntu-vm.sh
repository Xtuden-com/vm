#
# Host: Requires: vagrant VBoxManage qemu-img ovftool
#       ovftool from https://developercenter.vmware.com/tool/ovf/3.5.2
# Guest: Requires: systemd-services (for hostnamectl)


OBS_PROJECT=isv:ownCloud:community	# default...
OBS_MIRRORS=http://download.opensuse.org/repositories
DOO_MIRRORS=http://download.owncloud.org/download/repositories
DOO_PROJECT=9.0				# default
oc_ce=oc9ce				# keep in sync with directory name here.

test -n "$OC_REPO_URL" && DOO_MIRRORS=$OC_REPO_URL

test -z "$DEBUG" && DEBUG=true	# true: skip system update, disk sanitation, ... for speedy development.
                        	# false: do everything for production, also disable vagrant user.

mysql_pass=admin		# KEEP in sync with check-init.sh

if [ "$1" = "-h" ]; then
  echo "Usage: $0 [OBS_PROJECT]"
  echo "default OBS_PROJECT is '$DOO_PROJECT'"
  exit 1
fi
if [ -n "$1" ]; then
  OBS_PROJECT=$1
  DOO_PROJECT=$1
fi

EXPECTED_VERSION="-$2"

cd $(dirname $0)
mkdir -p test
rm -f    test/seen-login-page.html	# will be created during build...

sh ./pull_extra_apps.sh $OC_APP_URLS || exit 1

## An LTS operating system for production.
#buildPlatform=xUbuntu_14.04	# matches an OBS target.	at download.opensuse.org
buildPlatform=Ubuntu_14.04	# matches an OBS target.	at download.owncloud.org
vmBoxName=ubuntu/trusty64
vmBoxUrl=https://vagrantcloud.com/ubuntu/boxes/trusty64/versions/14.04/providers/virtualbox.box

## An alternate operating system for testing portability ...
# buildPlatform=xUbuntu_15.04	# matches an OBS target.
# vmBoxName=ubuntu/vivid64
# vmBoxUrl=https://vagrantcloud.com/ubuntu/boxes/vivid64/versions/20150722.0.0/providers/virtualbox.box

## recent debian
# buildPlatform=Debian_8.0	# matches an OBS target.
# vmBoxName=deb/jessie-amd64	# starts with 396 MB.
# vmBoxUrl=https://atlas.hashicorp.com/debian/boxes/jessie64/versions/8.1.1/providers/virtualbox.box

# OBS_REPO=$OBS_MIRRORS/$(echo $OBS_PROJECT | sed -e 's@:@:/@g')/$buildPlatform
OBS_REPO=$DOO_MIRRORS/$(echo $DOO_PROJECT | sed -e 's@:@:/@g')/$buildPlatform
OBS_REPO_APCU=$OBS_MIRRORS/isv:/ownCloud:/devel/$buildPlatform
# OBS_REPO_PROXY=$OBS_MIRRORS/isv:/ownCloud:/community:/8.2:/testing:/$buildPlatform

while true; do
  echo "fetching $OBS_REPO/Packages ..."
  ocVersion=$(curl -s -L $OBS_REPO/Packages | grep -a1 'Package: owncloud$' | grep Version: | head -n 1 | sed -e 's/Version: /owncloud-/')
  if [ -z "$ocVersion" ]; then
    curl -s -L $OBS_REPO/Packages
    echo ""
    echo "ERROR: failed to parse version number of owncloud from $OBS_REPO/Packages"
    exit 1
  fi
  # ocVersion=owncloud-8.1.0-6
  # ocVersion=owncloud-8.1.2~RC1-6.1
  test -z "$ocVersion" && { echo "ERROR: Cannot find owncloud version in $OBS_REPO/Packages -- Try again later"; exit 1; }
  echo $ocVersion
  if [ "${ocVersion#*$EXPECTED_VERSION}" != "$ocVersion" ]; then
    break
  else
    echo expected version $EXPECTED_VERSION not seen in project $OBS_REPO
    echo waiting 10 min ....
    sleep 600
  fi
done
ocVersion=$(echo $ocVersion | tr '~' -)
test -n "$OC_NAME_SUFFIX" && ocVersion="$ocVersion-$OC_NAME_SUFFIX"
vmName=$(echo $ocVersion | sed -e "s/owncloud/$oc_ce/")

echo $vmName
sleep 3
sleep 2
sleep 1

# don't use + with the image name, github messes up
imageName=$buildPlatform-$ocVersion-$(date +%Y%m%d%H%M)
$DEBUG && imageName=$imageName-DEBUG

cat > Vagrantfile << EOF
# CAUTION: Do not edit. Autogenerated contents.
# This Vagrantfile is created by $0 "$@"
#

VAGRANTFILE_API_VERSION = "2"

Vagrant.configure(VAGRANTFILE_API_VERSION) do |config|
 # Every Vagrant virtual environment requires a box to build off of.
  config.vm.box = "$vmBoxName"
  config.vm.define "$vmName"		# need this, or the name is always 'default'

  # avoids 'stdin: is not a tty' error.
  config.ssh.shell = "bash -c 'BASH_ENV=/etc/profile exec bash'" 

  # The url from where the 'config.vm.box' box will be fetched if it
  # doesn't already exist on the user's system. Normally not needed.
  config.vm.box_url = "$vmBoxUrl"

  # forward http
  config.vm.network :forwarded_port, guest: 80, host: 8888
  # forward https
  config.vm.network :forwarded_port, guest: 443, host: 4443
  # forward ssh (needs the id attribute to not conflict with a default forwarding at build time)
  config.vm.network :forwarded_port, id: 'ssh', guest: 22, host: 2222


  config.vm.provider :virtualbox do |vb|
      vb.name = "$imageName"
      # speed up: Force the VM to use NAT'd DNS:
      vb.customize [ "modifyvm", :id, "--natdnshostresolver1", "on" ]
      vb.customize [ "modifyvm", :id, "--natdnsproxy1", "on" ]
      vb.customize [ "modifyvm", :id, "--memory", 2048 ]
      vb.customize [ "modifyvm", :id, "--cpus", 1 ]
  end

  ## this is run as user root, apparently. I'd expected user vagrant ...
  config.vm.provision "shell", inline: <<-SCRIPT
		set -x
		userdel --force ubuntu		# backdoor?
		useradd owncloud -m		# group owncloud not yet exists
		useradd admin -m -g admin	# group admin already exists
		/bin/echo -e "root:admin\nadmin:admin\nowncloud:owncloud" | chpasswd
		$DEBUG || rm -f /etc/sudoers.d/vagrant
		echo 'admin ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/admin
		echo 'owncloud ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/owncloud
		
		# prepare repositories
		wget -q $OBS_REPO/Release.key -O - | apt-key add -
		sh -c "echo 'deb $OBS_REPO /' >> /etc/apt/sources.list.d/owncloud.list"
		wget -q $OBS_REPO_APCU/Release.key -O - | apt-key add -
		sh -c "echo 'deb $OBS_REPO_APCU /' >> /etc/apt/sources.list.d/owncloud.list"

		# attention: apt-get update is horribly slow when not connected to a tty.
		export DEBIAN_FRONTEND=noninteractive TERM=ansi LC_ALL=C
		apt-get -q -y update

		$DEBUG || aptitude full-upgrade -y
		$DEBUG || apt-get -q -y autoremove

		# install packages.
		apt-get install -q -y language-pack-de figlet
		

		#install additional software
		apt-get update
		apt-get -q -y install git

		## Install APCU 4.0.7 from the already registered backports repo.
		## Main trusty only has 4.0.2 which is not good enough.
		apt-get install -q -y php5-apcu/trusty-backports

		## Install Redis. The upstream php5-redis is too old. We try pecl.
		## https://github.com/owncloud/enterprise/issues/946
		apt-get install -q -y redis-server
		apt-get install -q -y php-pear php5-dev php5-ldap
		pecl install redis

		# set hostname 'owncloud' and localhost
		sed -i 's/127.0.0.1 localhost/127.0.0.1 localhost owncloud/g' /etc/hosts
		hostnamectl set-hostname owncloud

		# set servername directive to avoid warning about fully qualified domain name when apache restarts
		# it must be set after apache2 is setup, that is why we install apache here as well.
		apt-get install apache2 -q -y
		sudo sh -c "echo 'ServerName owncloud' >> /etc/apache2/apache2.conf"

		debconf-set-selections <<< 'mysql-server mysql-server/root_password password $mysql_pass'
		debconf-set-selections <<< 'mysql-server mysql-server/root_password_again password $mysql_pass'
		apt-get install -q -y owncloud php5-libsmbclient

		# Workaround for https://github.com/owncloud/core/issues/19479
		# This silences a bogus check in apps/files_external/lib/smb.php#L297-L303
		# apt-get install -q -y smbclient

		# https://central.owncloud.org/t/owncloud-ubuntu-appliance-has-broken-php5-libsmbclient/6256/11
		# indicates that package smbclient is also needed:
		apt-get install -q -y smbclient

		#### 
		# wget -q $OBS_REPO_PROXY/Release.key -O - | apt-key add -
		# sh -c "echo 'deb $OBS_REPO_PROXY /' >> /etc/apt/sources.list.d/owncloud.list"
		# apt-get -q -y update
		# apt-get install -q -y owncloud-app-proxy
		#### 

		curl -sL localhost/owncloud/ | grep login || { curl -sL localhost/owncloud; exit 1; } # did not start at all??
		curl -sL localhost/owncloud/ > /vagrant/test/seen-login-page.html

		## FIXME: the lines below assume we are root. While most other parts of the
		## script assume, we are a regular user and need sudo.

		# add extra apps, if any
		test -d /vagrant/apps && cp -a /vagrant/apps/* /var/www/owncloud/apps/
		test -d /vagrant/apps && chown -R www-data:www-data /var/www/owncloud/apps/*

		# hook our scripts. Specifically the check-init.sh upon boot.
		mkdir -p /var/scripts
		cp /vagrant/*.{php,sh} /var/scripts
		chmod a+x /var/scripts/*.{php,sh}
		$DEBUG || echo 'userdel --force vagrant' >> /var/scripts/check-init.sh
		sudo sed -i -e 's@exit@bash -x /var/scripts/check-init.sh; exit@' /etc/rc.local
		echo >> /home/admin/.profile 'test -f /var/scripts/setup-when-admin.sh && sudo bash /var/scripts/setup-when-admin.sh'

		# make things nice.
		mv /var/scripts/index.php /var/www/html/index.php && rm -f /var/www/html/index.html

		# prepare https
		a2enmod ssl headers
		a2dissite default-ssl
		bash /var/scripts/self-signed-ssl.sh

		# Install apps we want # https://github.com/owncloud/vm/issues/9
		# bash /var/scripts/install-additional-apps.sh

		# Set RAMDISK for better performance
		echo 'none /tmp tmpfs,size=6g defaults' >> /etc/fstab
		
		# Prepare cron.php to be run every 15 minutes
		# The user still has to activate it in the settings GUI
		sudo crontab -u www-data -l | { cat; echo "*/15  *  *  *  * php -f /var/www/owncloud/cron.php > /dev/null 2>&1"; } | crontab -u www-data -
		
		# "zero out" the drive...
		$DEBUG || dd if=/dev/zero of=/EMPTY bs=1M || true
		$DEBUG || rm -f /EMPTY || true
		sync
		shutdown -h now
  SCRIPT
end
EOF

# make sure it is not running. Normally, this prints "VM not created. Moving on..."
vagrant destroy -f

# do all vagrant calls from within the working directory, or retrive
# vmID=$(vagrant global-status | grep $vmName | sed -e 's/ .*//')
vagrant up
vagrant vbguest --status

sleep 10
## cannot do vagrant halt here, if the vagrant user was deleted.
# VBoxManage controlvm $imageName acpipowerbutton || true
#
# FIXME: VirtualBox 5.x says
# VBoxManage: error: Machine 'xUbuntu_14.04-owncloud-8.2.0-4.1-201511161821-DEBUG' is not currently running
#
echo + VBoxManage controlvm $imageName acpipowerbutton
while ! ( VBoxManage controlvm $imageName acpipowerbutton 2>&1 | egrep '(is not currently running|state: PoweredOff)' ); do
  VBoxManage controlvm $imageName acpipowerbutton 2>&1 | grep 'state: PoweredOff'
  echo waiting for PoweredOff ...
  sleep 10
done

## prepare for bridged network, done after building, to avoid initial ssh issues.
# VBoxManage modifyvm $imageName --nic1 bridged
# VBoxManage modifyvm $imageName --bridgeadapter1 wlan0
# VBoxManage modifyvm $imageName --macaddress1 auto
#
## VBoxManage modifyvm $imageName --resize 40000	# also needs: resize2fs -p -F /dev/DEVICE

## https://github.com/owncloud/vm/issues/13
VBoxManage sharedfolder remove $imageName --name vagrant

## the seen-login-page.html should be here by now. 
## Self-test: abort here, if it does not look sane.
if [ -z "$(grep login test/seen-login-page.html)" ]; then
  cat test/seen-login-page.html
  echo "\n"
  echo "ERROR: The word 'login' does not appear on the login page."
  echo "Check for earlier errors."
  exit 1;
fi

## export is much better than copying the disk manually.
rm -f img/*			# or VBoxManage export fails with 'already exists'
mkdir -p img
VBoxManage export $imageName -o img/$imageName.ovf || exit 0


## ---------------------
# VBoxImagePath=$(VBoxManage list hdds | grep "/$imageName/")
# #-->Location:       /home/$USER/VirtualBox VMs/ownCloud-8.1.1+xUbuntu_14.04/box-disk1.vmdk
# VBoxImagePath=/${VBoxImagePath#*/}	# delete Location: prefix
# cp "$VBoxImagePath" $imageName.vmdk
vagrant destroy -f

cd img
env DEBUG=$DEBUG sh -x ../convert-from-ovf.sh $imageName.ovf
