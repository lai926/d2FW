#!/bin/bash
#credits to @BasRaayman and @inchenzo

INTERFACE="tun0"
DEFAULT_NET="10.8.0.0/24"
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

while getopts "a:" opt; do
  case $opt in
    a) action=$OPTARG ;;
    *) echo 'Not a valid command' >&2
       exit 1
  esac
done

reset_ip_tables () {

  # start iptables service if not started
  if service iptables status | grep -q dead; then
    service iptables start
  fi

  # reset iptables to default
  iptables -P INPUT ACCEPT
  iptables -P FORWARD ACCEPT
  iptables -P OUTPUT ACCEPT

  iptables -F
  iptables -X

  # allow openvpn
  if ( ip a | grep -q "tun0" ) && [ $INTERFACE == "tun0" ]; then
    if ! iptables-save | grep -q "POSTROUTING -s 10.8.0.0/24"; then
      iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o eth0 -j MASQUERADE
    fi
    iptables -A INPUT -p udp -m udp --dport 1194 -j ACCEPT
    iptables -A FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT
    iptables -A FORWARD -s 10.8.0.0/24 -j ACCEPT
  fi
}

get_platform_match_str () {
  local val="psn-4"
  if [ "$1" == "psn" ]; then
    val="psn-4"
  elif [ "$1" == "xbox" ]; then
    val="xboxpwid:"
  elif [ "$1" == "steam" ]; then
    val="steamid:"
  fi
  echo $val
}

auto_sniffer () {
  echo -e "${RED}Press any key to stop sniffing. DO NOT CTRL C${NC}"
  sleep 1

  #sniff the ids based on platform
  #if [ "$1" == "psn" ]; then
    ngrep -l -q -W byline -d $INTERFACE "psn-4" udp | grep --line-buffered -o -P 'psn-4[0]{8}\K[A-F0-9]{7}' | tee -a "$2" &
  #elif [ "$1" == "xbox" ]; then
    ngrep -l -q -W byline -d $INTERFACE "xboxpwid:" udp | grep --line-buffered -o -P 'xboxpwid:\K[A-F0-9]{32}' | tee -a "$2" &
  #elif [ "$1" == "steam" ]; then
    ngrep -l -q -W byline -d $INTERFACE "steamid:" udp | grep --line-buffered -o -P 'steamid:\K[0-9]{17}' | tee -a "$2" &
  #fi

  #run infinitely until key is pressed
  while [ true ] ; do
    read -t 1 -n 1
    if [ $? = 0 ] ; then
      break
    fi
  done
  pkill -15 ngrep
}

install_dependencies () {

  # enable ip forwarding
  sysctl -w net.ipv4.ip_forward=1 > /dev/null

  # disable ufw firewall
  ufw disable > /dev/null
  service ufw stop > /dev/null
  systemctl disable ufw > /dev/null

  # check if openvpn is already installed
  if ip a | grep -q "tun0"; then
    yn="n"
  else 
    echo -e -n "${GREEN}Would you like to install OpenVPN?${NC} y/n: "
    read yn
    yn=${yn:-"y"}
  fi
  
  if [[ $yn =~ ^(y|yes)$ ]]; then

    echo -e -n "${GREEN}Is this for a local/home setup? ${RED}(Answer no if AWS/VPS)${NC} y/n: "
    read ans
    ans=${ans:-"y"}

    if [[ $ans =~ ^(y|yes)$ ]]; then
      # Put all IPs except for IPv6, loopback and openVPN in an array
      ip_address_list=( $( ip a | grep inet | grep -v -e 10.8. -e 127.0.0.1 -e inet6 | awk '{ print $2 }' | cut -f1 -d"/" ) )
      
      echo "Please enter the number which corresponds to the private IP address of your device that connects to your local network: "
      i=1
      # Show all addresses in a numbered list
      for address in "${ip_address_list[@]}"; do
        echo "    $i) $address"
        ((i++))
      done
      
      # Have them type out which IP connects to the internet and set IP address based off of that
      read -p "Choice: " ip_line_number
      ip_list_index=$((ip_line_number - 1))
      ip="${ip_address_list[$ip_list_index]}"
      if [ -z $ip ]; then
        echo "Ip does not exist."
        exit 1;
      fi
    else
      # get public ipv4 address
      ip=$(dig +short myip.opendns.com @resolver1.opendns.com)
    fi;

    echo -e "${RED}Installing dependencies. Please wait while it finishes...${NC}"
    apt-get update > /dev/null
  
    # install dependencies
    DEBIAN_FRONTEND=noninteractive apt-get -y -q install iptables iptables-persistent ngrep nginx > /dev/null
    systemctl enable iptables

    # start nginx web service
    service nginx start

    echo -e "${RED}Installing OpenVPN. Please wait while it finishes...${NC}"
    curl -s -O https://raw.githubusercontent.com/angristan/openvpn-install/master/openvpn-install.sh > /dev/null
    chmod +x ./openvpn-install.sh
    (ENDPOINT="$ip" APPROVE_INSTALL=y APPROVE_IP=y IPV6_SUPPORT=n PORT_CHOICE=1 PROTOCOL_CHOICE=1 DNS=1 COMPRESSION_ENABLED=n CUSTOMIZE_ENC=n CLIENT=client PASS=1 ./openvpn-install.sh) &
    wait;

    # move openvpn config to public web folder
    cp /"$SUDO_USER"/client.ovpn /var/www/html/client.ovpn
    
    clear
    echo -e "${GREEN}You can download the openvpn config from ${BLUE}http://$ip/client.ovpn"
    echo -e "${GREEN}If you are unable to access this file, you may need to allow/open the http port 80 with your vps provider."
    echo -e "Otherwise you can always run the command cat /root/client.ovpn and copy/paste ALL of its contents in a file on your PC."
    echo -e "It will be deleted automatically in 15 minutes for security reasons."
    echo -e "Be sure to import this config to your router and connect your consoles before proceeding any further.${NC}"

    # stop nginx web service after 15 minutes and delete openvpn config
    nohup bash -c 'sleep 900 && service nginx stop
