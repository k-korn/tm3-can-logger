# tm3-can-logger
CAN data logger and display toolkit for vehicle data dashboard.
Result will look like this, creating a realtime dashboard for Tesla Model 3: https://i.imgur.com/RixTS02.jpg

## Principles of operation
* CAN data is received by MCP2515 connected to a Raspberry Pi 
* Messages of interest are extracted (and parsed) by included can-logger.pl
* Messages are posted to locally installed Mosquitto MQTT broker, which has a neat feature of providing WebSockets interface in addition to standard MQTT port.
* Raspberry Pi acts as Wi-Fi AP for the vehicle, also serving a simple HTML page (stylized with MDB, https://mdbootstrap.com/)
* Javascript MQTT/Websocket client receives data messages over WebSockets and performs one simple action: if there is a page element with ID matching the topic of incoming message - set this element content to message content.
## Hardware
The [device](https://i.imgur.com/HkXP3x4.png) consists of:
- Raspberry Pi 3B+
- [MCP2515 module](https://www.makerfabs.com/can-module-mcp2515.html) 
- [Model 3 OBDII adapter](https://gpstrackingcanada.com/product/tesla-obd2-adapter-hrn-ct20t11/)
- Huawei 4G modem for data connectivity

Initial version of this project used generic ELM327 dongle over Bluetooth. However, it was not capable of processing full 500kbps of CAN data Tesla vehicles send. 

Instead, proper (and cheaper) implementation of CAN bus interface using MCP2515 module is used.
MCP2515  module is linked to Raspberry PI 3B+ using this guide: https://www.raspberrypi.org/forums/viewtopic.php?t=141052

## OS configuration
Device uses regular Raspbian with few modifications:
- Realtime kernel is a strict requirement. You can build one yourself, or get a prebuilt one from RealtimePi here: https://github.com/guysoft/RealtimePi/releases
- spi0-hw-cs, mcp2515-can0 overlays - see included boot/config.txt
- Realtime priorities boosted for mcp251x, spi kernel threads - see included etc/rc.local

Without these modifications you will see significant (10%) error rate on CAN interface, **which can interfere with vehicle operation**.

##Networking and Wi-Fi access point.
Raspberry Pi is connected to the Internet using Huawei USB modem. It is visible as eth1 device from the OS, where DHCP can be used to obtain IP address and other details.
Raspberry Pi itself is doing DHCP, NAT and routing for the vehicle via hostapd Wi-FI AP daemon.
There is a caveat, however: Tesla browser is restricted from accessing private networks (192.168.x.x, 10.x.x.x, etc).
So "local" network at Raspberry PI wlan0 interface needs to use some rarely-used public IP range, for example 5.4.3.0/24
As a result, RPI has address of 5.4.3.1 and clients use 5.4.3.xx range.

## Data Flow
CAN data is obtained by "candump" utility, launched with a set of filters to match only messages we need.
It is then processed by can-logger.pl script, which used DBC-like data descriptions to extract data from binary signals.
Perl script publishes results to Mosquitto MQTT broker, which has couple of very useful features:
 - WebSocket protocol support 
 - Ability to act as a simple HTTP server (by http_dir config option), eliminating the need for actual HTTP server like Nginx.
MQTT data is received by JS MQTT [client](https://www.eclipse.org/paho/clients/js/), which for every message perform the following:
- If HTML DOM element with ID equal to message topic exists, set its content to be equal to the message content.
Resulting page is displayed in Tesla car browser (at http://5.4.3.1:3000) , providing live view dashboard with CAN bus internal data.
- optionally, Zabbix integration can be enabled to store data history.

## Performance
This solution is simple and relatively fast: with latency measured in milliseconds, it is able to display at least 500-600 item value changes per second (required performance for the data currently on dashboard is 200-300 values per second)
Perl CAN data parser itself is able to process up to 2500 messages per second at least.
