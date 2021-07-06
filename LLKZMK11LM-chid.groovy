/*
 *  https://community.smartthings.com/t/device-handler-for-aqara-wired-wall-switch/101062/187
 *  for Aqara Switch QBKG12LM - Child Switch
 *
 *  modify code from Smartthings ZigBee Switch & Diego Schich & Zooz Power Strip Outlet
 *
 *  Leza, 10-Aug-2019
 */

metadata {
	definition (name: "Aqara LLKZMK11LM Child Switch", namespace: "Leza", author: "LPT", vid:"generic-switch-power-energy") {
        capability "Actuator"
		capability "Switch"
        capability "Temperature Measurement"
        capability "Voltage Measurement"
		capability "Sensor"
		capability "Refresh"
	}
    
    simulator { }

	tiles(scale: 2) {
		multiAttributeTile(name:"switch", type: "lighting", width: 6, height: 4, canChangeIcon: true){
			tileAttribute ("device.switch", key: "PRIMARY_CONTROL") {
				attributeState "on", label:'${name}', action:"switch.off", icon:"st.switches.light.on", backgroundColor:"#00A0DC", nextState:"turningOff"
				attributeState "off", label:'${name}', action:"switch.on", icon:"st.switches.light.off", backgroundColor:"#ffffff", nextState:"turningOn"
				attributeState "turningOn", label:'${name}', action:"switch.off", icon:"st.switches.light.on", backgroundColor:"#00A0DC", nextState:"turningOff"
				attributeState "turningOff", label:'${name}', action:"switch.on", icon:"st.switches.light.off", backgroundColor:"#ffffff", nextState:"turningOn"
			}
			tileAttribute("device.lastCheckin", key: "SECONDARY_CONTROL") {
				attributeState("default", label:'Last Update: ${currentValue}')
			}
		}
		
		valueTile("voltage", "device.voltage", width: 2, height: 2) {
			state "voltage", label:'${currentValue} V', icon:"st.Appliances.appliances17"
		}
		valueTile("temperature", "device.temperature", width: 2, height: 2) {
			state "temperature", label:'${currentValue} °C', icon:"st.Weather.weather2"
		}
		standardTile("refresh", "device.refresh", width: 2, height: 2) {
			state "default", label:'Refresh', action: "refresh", icon:"st.secondary.refresh-icon"
		}

		main (["switch"])
		details(["switch", "voltage", "temperature", "refresh"])
	}
}

def parse(String description) {
	try {
		logDebug "child parse(): description is $description"
		def cluster = zigbee.parseDescriptionAsMap(description)
		logDebug "parse: descMap is $cluster"
	} catch(e) {
		logDebug "child parse() failed: ${e}"
	}
}

def installed() {
	logDebug "child installed: ${device}"
}

def updated() {	
	logDebug "child updated: ${device}"
	parent.childUpdated(device.deviceNetworkId)
}

def on() {
	logDebug "child on: ${device}"
	parent.childOn(device.deviceNetworkId)	
}

def off() {
	logDebug "child off: ${device}"
	parent.childOff(device.deviceNetworkId)	
}

def refresh() {
	logDebug "child refresh: ${device}"
	parent.childRefresh(device.deviceNetworkId)
}

private logDebug(msg) {
	parent.logDebug("$msg")
}
