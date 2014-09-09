#!/bin/bash

# I thought I should give my few hours of messing about to the 
# world under the auspices of the Apache v2 license 
# http://www.apache.org/licenses/
# Go crazy with this, but please remember where it came from!

# This _IS_ messy, it's not great code, it was meant so that I could
# experiment with Swift rather than be an example of useful code.

# Graham Moore 2014.

echo "=========="
echo "Prerequisites:"
echo -e "\t* You're running on ->\t\tAmazon"
echo -e "\t* The instance is at least->\tt1.medium "
echo -e "\t* The OS is ->\t\t\tUbuntu 12.04.1 LTS"
echo -e "\t* ...and port 8080 is enabled in your security group settings"
echo 
echo -n "Continue? (y/N) "
read decide
case $decide in 
	Y|y) ;;
	*) echo "Bailing out"; exit 1;;
esac
echo "=========="

# TODO - check this stuff and bail if it fails:
# ami-id
# hostname
# instance-id
# instance-type
# local-ipv4
# profile
# public-hostname
# public-ipv4
# public-keys/
# security-groups

local_instance_type=`curl -s http://169.254.169.254/latest/meta-data/instance-type`
ami_id=`curl -s http://169.254.169.254/latest/meta-data/ami-id`
pub_ip=`curl -s http://169.254.169.254/latest/meta-data/public-ipv4`
local_ip=`curl -s http://169.254.169.254/latest/meta-data/local-ipv4`

#for amazoninfo in $pub_ip $local_ip $local_instance_type; do 
	#if [ "x$amazoninfo" == "x" ] ; then 
		#echo "Unable to determine variables, bailing out..."
		#exit 1	
	#fi
#done

if [ "x$local_instance_type" != "xm1.medium" ] ; then 
	echo -e "You're running on $local_instance_type.\nIf this is a lower spec than m1.medium, this might be tedious, you might run out of mem very soon"
	echo -n "Carry on? (Y/N) "
	read outcome
	case $outcome in 
		yY) echo Continuing ;;
		nN) echo Bailing out...;  exit 1 ;;
		*)  echo Needed Y/N, bailing out... ;  exit 1 ;;
	esac
fi
## Done with checking stuff
		
# clean up first!
## remove running services
service memcached stop 2>&1 1>/dev/null 
service rsync stop 2>&1 1>/dev/null 
swift-init all stop 2>&1 1>/dev/null 
service ntp stop 2>&1 1>/dev/null 

## umount existing volumes..
df -h | grep "/mnt/sdb1" 2>&1 1>/dev/null
if [ $? == 0 ] ; then umount -f /mnt/sdb1; fi

## remove old config.
cd /etc/swift
rm -rf *.builder *.ring.gz backups/*.builder backups/*.ring.gz /srv/sdb1* /srv/?/

# Start creating new swift install config
## SSL
openssl req -new -x509 -nodes -out /etc/swift/cert.crt -keyout /etc/swift/cert.key -subj "/CN=GB/" 2>&1 1>/dev/null 

## Packages
apt-get -qq install -y swift-proxy swift-account swift-container swift-object swift memcached rsync xfsprogs ntp rand

cat >/etc/swift/swift.conf <<EOF
[swift-hash]
# random unique string that can never change (DO NOT LOSE)
swift_hash_path_suffix = `od -t x8 -N 8 -A n </dev/random`
EOF

## Memcached
perl -pi -e "s/-l 127.0.0.1/-l $local_ip/" /etc/memcached.conf

## storage device
cp /etc/fstab /etc/fstab-`date +%s`
if [ ! -f /etc/fstab-orig ]; then
 # paranoid - keep an original copy
 cp /etc/fstab /etc/fstab-orig
fi

## create a sparse file, ready for 5gb of disk in a file, make an fs, edit fstab and mount it!
dd if=/dev/zero of=/srv/swift-disk bs=1024 count=0 seek=5000000 2>&1 1>/dev/null
mkfs.xfs -f -q -i size=1024 /srv/swift-disk
echo "/srv/swift-disk /mnt/sdb1 xfs loop,noatime,nodiratime,nobarrier,logbufs=8 0 0" >> /etc/fstab
mount /mnt/sdb1
df -h | grep "/mnt/sdb1" 2>&1 1>/dev/null
if [ $? != 0 ] ; then 
  echo "The filesystem for the storage failed to mount... bailing out..."
  exit 1
fi

## The schema for having 5 swift nodes on one server is messy, but this makes it.
for x in {0..4}; do 
 mkdir -p /mnt/sdb1/${x}
 ln -s /mnt/sdb1/${x} /srv/${x}
 mkdir -p /srv/${x}/node/sdb${x}
 mkdir -p /var/cache/swift/${x}
done

## Make sure all directories for the config are in place
mkdir -p /etc/swift/object-server /etc/swift/container-server /etc/swift/account-server /var/run/swift
chown -R swift.swift /etc/swift/object-server /etc/swift/container-server /etc/swift/account-server /var/run/swift /var/cache/swift

## Create the rings.
cd /etc/swift
swift-ring-builder account.builder create 18 3 1
swift-ring-builder container.builder create 18 3 1
swift-ring-builder object.builder create 18 3 1

for z in {0..4} ; do 
 export ZONE=${z}                    # set the zone number for that storage device
 export STORAGE_LOCAL_NET_IP=$local_ip    # and the IP address
 export WEIGHT=100               # relative weight (higher for bigger/faster disks)
 export DEVICE=sdb${z}
 swift-ring-builder account.builder add r1z$ZONE-$STORAGE_LOCAL_NET_IP:60${z}2/$DEVICE $WEIGHT
 swift-ring-builder container.builder add r1z$ZONE-$STORAGE_LOCAL_NET_IP:60${z}1/$DEVICE $WEIGHT
 swift-ring-builder object.builder add r1z$ZONE-$STORAGE_LOCAL_NET_IP:60${z}0/$DEVICE $WEIGHT
done 
 #swift-ring-builder account.builder add z$ZONE-$STORAGE_LOCAL_NET_IP:60${z}2/$DEVICE $WEIGHT
 #swift-ring-builder container.builder add z$ZONE-$STORAGE_LOCAL_NET_IP:60${z}1/$DEVICE $WEIGHT
 #swift-ring-builder object.builder add z$ZONE-$STORAGE_LOCAL_NET_IP:60${z}0/$DEVICE $WEIGHT

swift-ring-builder account.builder rebalance
swift-ring-builder container.builder rebalance
swift-ring-builder object.builder rebalance
chown -R swift:swift /etc/swift
## Done making the rings

cat >/etc/swift/proxy-server.conf <<EOF
[DEFAULT]
cert_file = /etc/swift/cert.crt
key_file = /etc/swift/cert.key
bind_port = 8080
workers = 8
user = swift
expose_info = true

[pipeline:main]
pipeline = healthcheck cache tempauth proxy-server

[app:proxy-server]
use = egg:swift#proxy
allow_account_management = true
account_autocreate = true

[filter:tempauth]
use = egg:swift#tempauth
user_system_root = testpass .admin https://$pub_ip:8080/v1/AUTH_system

[filter:healthcheck]
use = egg:swift#healthcheck

[filter:cache]
use = egg:swift#memcache
memcache_servers = $local_ip:11211
EOF


## Rsync

cat >/etc/rsyncd.conf <<EOF
uid = swift
gid = swift
log file = /var/log/rsyncd.log
pid file = /var/run/rsyncd.pid
address = 0.0.0.0
EOF

for z in {0..4}; do 
cat >>/etc/rsyncd.conf <<EOF
[account60${z}2]
max connections = 2
path = /srv/${z}/node/
read only = false
lock file = /var/lock/account60${z}2.lock

EOF
done

for z in {0..4}; do 
cat >>/etc/rsyncd.conf <<EOF
[container60${z}1]
max connections = 2
path = /srv/${z}/node/
read only = false
lock file = /var/lock/container60${z}1.lock

EOF
done

for z in {0..4}; do 
cat >>/etc/rsyncd.conf <<EOF
[object60${z}0]
max connections = 2
path = /srv/${z}/node/
read only = false
lock file = /var/lock/object60${z}0.lock

EOF
done

sed -i 's/RSYNC_ENABLE=false/RSYNC_ENABLE=true/g' /etc/default/rsync
service rsync start

## Build object, container and account config
## swift-{container,object,account} rings
for z in {0..4} ; do 
cat >/etc/swift/account-server/${z}.conf <<EOF
[DEFAULT]
devices = /srv/${z}/node
mount_check = false
disable_fallocate = true
bind_port = 60${z}2
user = swift
#log_facility = LOG_LOCAL2
recon_cache_path = /var/cache/swift/${z}

[pipeline:main]
pipeline = recon account-server

[app:account-server]
use = egg:swift#account

[filter:recon]
use = egg:swift#recon

[account-replicator]
vm_test_mode = yes

[account-auditor]

[account-reaper]
EOF
done

for z in {0..4} ; do 
cat >/etc/swift/container-server/${z}.conf <<EOF
[DEFAULT]
devices = /srv/${z}/node
mount_check = false
disable_fallocate = true
bind_port = 60${z}1
user = swift
#log_facility = LOG_LOCAL2
recon_cache_path = /var/cache/swift/${z}

[pipeline:main]
pipeline = recon container-server

[app:container-server]
use = egg:swift#container

[filter:recon]
use = egg:swift#recon

[container-replicator]
vm_test_mode = yes

[container-updater]

[container-auditor]

[container-sync]

EOF
done

for z in {0..4}; do 
cat >/etc/swift/object-server/${z}.conf <<EOF
[DEFAULT]
devices = /srv/${z}/node
mount_check = false
disable_fallocate = true
bind_port = 60${z}0
user = swift
log_facility = LOG_LOCAL2
recon_cache_path = /var/cache/swift/${z}

[pipeline:main]
pipeline = recon object-server

[app:object-server]
use = egg:swift#object

[filter:recon]
use = egg:swift#recon

[object-replicator]
vm_test_mode = yes

[object-updater]

[object-auditor]
EOF
done

chown -R swift:swift /etc/swift /mnt/sdb1 /srv/

mkdir -p /etc/swift/old/
for x in container-server object-server account-server; do 
    if [ -f /etc/swift/${x}.conf ]; then
        mv /etc/swift/${x}.conf /etc/swift/old/;  
    fi
done

## Restart all services
service memcached start
service rsync start
swift-init proxy start
service ntp start
swift-init all start

echo Sleeping for 60 seconds to allow the proxy to come up...
sleep 60

set -o xtrace
curl -k -v -H 'X-Storage-User: system:root' -H 'X-Storage-Pass: testpass' https://$local_ip:8080/auth/v1.0
set +o xtrace

echo -e "Public IP ->\t$pub_ip"
echo -e "Private IP ->\t$local_ip"
