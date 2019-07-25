#!/usr/bin/env bash

HOST_SERVER=10.0.0.200
IMAGES_DIR=/var/lib/libvirt/images
OFFICIAL_IMAGE=rhel-server-7.7-beta-1-x86_64-kvm.qcow2
PASSWORD_FOR_VMS='hubble!'
VIRT_DOMAIN='example.com'

### Let the user know that this will destroy his environment.

ANSWER=YES

if virsh list --all | egrep -q  'comp|net|ctrl|ceph|undercloud'
then
  unset ANSWER
  echo '*** WARNING ***'
  echo 'This procedure will destroy the environment you currently have'
  echo 'Type uppercase YES if you understand this and want to proceed'
  read -p 'Your answer > ' ANSWER
fi

[ "${ANSWER}" != "YES" ] && exit 1

### Clean the environment

if virsh net-list --all | egrep -q "provisioning|trunk"
then
  for NETWORK in provisioning trunk
  do
    virsh net-destroy ${NETWORK}   > /dev/null 2>&1
    virsh net-undefine ${NETWORK}  > /dev/null 2>&1
  done
fi

vbmc list | awk '/undercloud/ { print $2; }' | xargs vbmc delete
vbmc list | awk '/overcloud/ { print $2; }' | xargs vbmc delete

if firewall-cmd --get-active-zones | grep -q virt
then
  firewall-cmd --delete-zone=virt --permanent
  firewall-cmd --reload
fi

cd ${IMAGES_DIR}

if virsh list --all | egrep -q  'compute|networker|ctrl|ceph|undercloud'
then
  for VM in overcloud-ctrl0{1,2,3} overcloud-compute0{1,2} overcloud-networker overcloud-ceph0{1,2,3} undercloud
  do
    virsh destroy ${VM}  > /dev/null 2>&1
    virsh undefine ${VM} > /dev/null 2>&1
    rm -f ${IMAGES_DIR}/${VM}.qcow2 > /dev/null 2>&1
    rm -f ${IMAGES_DIR}/${VM}-storage.qcow2 > /dev/null 2>&1
  done
fi


### Create the networks required for environment.

cat > /tmp/provisioning.xml <<EOF
<network>
  <name>provisioning</name>
  <forward mode='nat'>
    <nat>
      <port start='1024' end='65535'/>
    </nat>
  </forward>
  <ip address="172.16.0.254" netmask="255.255.255.0"/>
</network>
EOF

cat > /tmp/trunk.xml <<EOF
<network>
  <name>trunk</name>
  <forward mode='nat'>
    <nat>
      <port start='1024' end='65535'/>
    </nat>
  </forward>
  <ip address="192.168.0.1" netmask="255.255.255.0"/>
</network>
EOF

for NETWORK in provisioning trunk
do
  virsh net-define /tmp/${NETWORK}.xml
  virsh net-autostart ${NETWORK}
  virsh net-start ${NETWORK}
done

# Add firewall rules
firewall-cmd --new-zone=virt --permanent
firewall-cmd --zone=virt --add-source=172.16.0.0/24 --permanent
firewall-cmd --zone=virt --add-source=192.168.0.0/24 --permanent
firewall-cmd --zone=virt --set-target=ACCEPT --permanent
firewall-cmd --reload

# Create virtual machines

# Download course specific config files for VM customization
#curl -o /tmp/open.repo http://classroom/open.repo

# Define config files for network interfaces on the undercloud node
cat > /tmp/ifcfg-eth0 << EOF
DEVICE="eth0"
BOOTPROTO="dhcp"
ONBOOT="yes"
TYPE="Ethernet"
NM_CONTROLLED="yes"
EOF

cat > /tmp/ifcfg-eth1 << EOF
DEVICE="eth1"
BOOTPROTO="none"
ONBOOT="yes"
TYPE="Ethernet"
IPADDR=192.168.0.253
NETMASK=255.255.255.0
GATEWAY=192.168.0.1
NM_CONTROLLED="no"
DNS1=8.8.8.8
EOF

# Define the /etc/hosts file
cat > /tmp/hosts <<EOF
127.0.0.1   localhost localhost.localdomain localhost4 localhost4.localdomain4
::1         localhost localhost.localdomain localhost6 localhost6.localdomain6

${HOST_SERVER}  demo
EOF

qemu-img create -f qcow2 test1.qcow2 30G
virt-resize --expand /dev/sda1 ${OFFICIAL_IMAGE} test1.qcow2
virt-customize -a test1.qcow2 \
  --hostname test1.example.com \
  --root-password password:${PASSWORD_FOR_VMS} \
  --uninstall cloud-init \
  --copy-in /tmp/hosts:/etc/ \
  --copy-in /tmp/ifcfg-eth0:/etc/sysconfig/network-scripts/ \
  --copy-in /tmp/ifcfg-eth1:/etc/sysconfig/network-scripts/ \
  --selinux-relabel

virt-install --ram 4096 --vcpus 1 --os-variant rhel7 \
  --disk path=${IMAGES_DIR}/test1.qcow2,device=disk,bus=virtio,format=qcow2 \
  --import --noautoconsole --vnc --network network:provisioning \
  --network network:trunk --name test1 \
  --cpu host,+vmx \
  --dry-run --print-xml > /tmp/test1.xml

rm /tmp/hosts
rm /tmp/ifcfg-eth0
rm /tmp/ifcfg-eth1
rm /tmp/open.repo

virsh define --file /tmp/test1.xml
rm /tmp/test1.xml

