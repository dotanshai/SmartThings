/*
 * Smartthings DH for 
 * Aqara Two-way Control Module Wireless Relay Controller . Product: LLKZMK11LM.
 * 
 * This handler is slightly modified version of DH for for Aqara Switch QBKG12LM
 * https://community.smartthings.com/t/device-handler-for-aqara-wired-wall-switch/101062/187
 *  use information from Smartthings ZigBee Switch & Diego Schich & Zooz Power Strip Outlet & Koenkk zigbee2mqtt
 *  & aonghusmor & veeceeoh
 *
 *  Leza, 10-Aug-2019
 */
 
 /*
  For device with FW 0x24
  RAW description 01 0104 0101 02 0B 0000 0003 0004 0005 0001 0002 000A 0006 0010 0B04 000C 02 0019 000A
  
  zbjoin: {"dni":"64AB","d":"00158D0006D4F038","capabilities":"8E",
    "endpoints":[{"simple":"01 0104 0101 02 0B 0000 0003 0004 0005 0001 0002 000A 0006 0010 0B04 000C 02 0019 000A",
	   "application":"24","manufacturer":"LUMI","model":"lumi.relay.c2acn01"},
	   {"simple":"02 0104 0101 02 04 0006 0010 0004 0005 00","application":"","manufacturer":"","model":""}],
	"parent":"0000","joinType":1,"joinDurationMs":1152,"joinAttempts":1}
	
	
	zbjoin: {"dni":"64AB","d":"00158D0006D4F038","capabilities":"8E",
	   "endpoints":[{"simple":"01 0104 0101 02 0B 0000 0003 0004 0005 0001 0002 000A 0006 0010 0B04 000C 02 0019 000A","application":"24","manufacturer":"LUMI","model":"lumi.relay.c2acn01"},
	                {"simple":"02 0104 0101 02 04 0006 0010 0004 0005 00","application":"","manufacturer":"","model":""}],"parent":"0000","joinType":1,"joinDurationMs":689,"joinAttempts":1}
	zbjoin: {"dni":"64AB","d":"00158D0006D4F038","capabilities":"8E",
	   "endpoints":[{"simple":"01 0104 0101 02 0B 0000 0003 0004 0005 0001 0002 000A 0006 0010 0B04 000C 02 0019 000A","application":"24","manufacturer":"LUMI","model":"lumi.relay.c2acn01"},
	                {"simple":"02 0104 0101 02 04 0006 0010 0004 0005 00","application":"","manufacturer":"","model":""}],"parent":"0000","joinType":1,"joinDurationMs":1152,"joinAttempts":1}
	
simple: a space separated string of hex values that contains the following pieces of information:

01 0104 0101 02 0B 0000 0003 0004 0005 0001 0002 000A 0006 0010 0B04 000C 02 0019 000A
    Endpoint 8
    Profile ID 16
    Device ID 16
    Device version 4
	Reserved       4
    Number of in/server clusters 8
    List of In/server clusters
    Number of out/client clusters
    List of out/client clusters

Clusters
0000 Basic

0000 0003 0004 0005 0001 0002 000A 0006 0010 0B04 000C

0x0000 	Basic
0x0001 	Power configuration
0x0002 	Device temperature configuration
0x0003 	Indentify
0x0004 	Groups
0x0005 	Scenes
0x0006 	ON/OFF
0x0007 	ON/OFF Switch configuration
0x0008 	Level Control
0x0009 	Alarms
0x000A 	Time
0x000B 	RSSI Location 

Analog Input (Basic) (Cluster ID 0x000c)
0x0B04 Electrical Measurement Cluster
0x0010 Binary Output (Basic) (Cluster ID0x0010) 
0x0019 OTA Upgrade



hubId 	10138ce9-274c-4a17-b4a4-204f1011b426
id 	ecf481c3-c509-46d5-960f-fee7d2d7f149
locationId 	6e776287-41cf-4967-81d4-8b4d12d6337f
data
{
    "deviceId": "1b3298ec-6655-4460-bdbd-43f766214bec"
}

hubId 	10138ce9-274c-4a17-b4a4-204f1011b426
id 	1cd66efe-dd81-47c1-aff9-86001fe97db6
locationId 	6e776287-41cf-4967-81d4-8b4d12d6337f
	
data 	
{
    "deviceId": "1b3298ec-6655-4460-bdbd-43f766214bec"
}

*/

metadata {
	definition (name: "Aqara LLKZMK11LM Main", namespace: "Leza", author: "LPT", vid:"generic-switch-power-energy") {
		capability "Actuator"
		capability "Switch"
		capability "Temperature Measurement"
		capability "Voltage Measurement"
		capability "Power Meter"
		capability "Energy Meter"
		capability "Sensor"
		capability "Configuration"
		capability "Refresh"
		capability "Health Check"
		
		(1..2).each {
			//attribute "sw${it}Power", "number"
			attribute "sw${it}Switch", "string"
			attribute "sw${it}Name", "string"
			command "sw${it}On"
			command "sw${it}Off"
		}

		fingerprint	profileId: "0104", deviceId: "0101", 
					inClusters: "0000 0003 0004 0005 0001 0002 000A 0006 0010 0B04 000C",
					outClusters: "0019,000A",
					manufacturer: "LUMI", model: "lumi.relay.c2acn01", deviceJoinName: "Aqara Dual Switch LLKZMK11LM"
	}	
	
	preferences {
		// Log Debug
		getBoolInput("debugOutput", "Enable Debug Logging", true)
	}

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
		
		valueTile("sw1Name", "device.sw1Name", decoration:"flat", width:5, height: 1) {
			state "default", label:'${currentValue}'
		}
		standardTile("sw1Switch", "device.sw1Switch", width:1, height: 1) {
			state "on", label:'ON', action:"sw1Off", backgroundColor: "#00A0DC"
			state "off", label:'OFF', action:"sw1On", backgroundColor:"#ffffff"
		}
		valueTile("sw2Name", "device.sw2Name", decoration:"flat", width:5, height: 1) {
			state "default", label:'${currentValue}'
		}
		standardTile("sw2Switch", "device.sw2Switch", width:1, height: 1) {
			state "on", label:'ON', action:"sw2Off", backgroundColor: "#00A0DC"
			state "off", label:'OFF', action:"sw2On", backgroundColor:"#ffffff"
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
		valueTile("power", "device.power", width: 3, height: 2) {
			state "power", label:'${currentValue} W', icon:"st.Appliances.appliances5"
		}
		valueTile("energy", "device.energy", width: 3, height: 2) {
			state "energy", label:'${currentValue} kWh', icon:"st.Health & Wellness.health7"
		}
		
		main (["switch"])
		details (detailsTiles)
	}
}

private getDetailsTiles() {	
	def tiles = ["switch"]
	(1..2).each {
		tiles << "sw${it}Name"
		tiles << "sw${it}Switch"
	}
    tiles << "voltage" << "temperature" << "refresh" << "power" << "energy"
	
//	logDebug "getDetailsTiles ${tiles}"
	return tiles
}

private getBoolInput(name, title, defaultVal) {
	input "${name}", "bool", 
	title: "${title}?", 
	defaultValue: "${defaultVal}", 
	required: false
}

// Globals - Key IDs
private Key_TEMPERATURE()	{ 0x03 }
private Key_RSSI()			{ 0x05 }
private Key_SWITCH_1()		{ 0x64 }
private Key_SWITCH_2()		{ 0x65 }
private Key_ENERGY_METER()	{ 0x95 }
private Key_POWER_METER()	{ 0x98 }

// ZigBee - Data Types
private ZB_Data_BOOLEAN()	{ 0x10 }
private ZB_Data_UINT8()		{ 0x20 }
private ZB_Data_UINT16()	{ 0x21 }
private ZB_Data_UINT64()	{ 0x27 }
private ZB_Data_INT8()		{ 0x28 }
private ZB_Data_FLOAT4()	{ 0x39 }

def installed() { 
	logDebug "installed()... device=${device} settings=${settings}"

	// Make sure the switch get created if using the new mobile app.
	runIn(30, createChildDevices)
}

def configure() {	
	logDebug "configure()... settings=${settings} childDevices=${childDevices}"
	updateHealthCheckInterval()
}

def updated() {	
	logDebug "updated()..."
	
	if (!isDuplicateCommand(state.lastUpdated, 3000)) {
		state.lastUpdated = new Date().time
		
		def cmds = []
		
		if (childDevices?.size() != 2)	createChildDevices()
		
		return cmds ? response(cmds) : []
	}
}

def createChildDevices() {
	logDebug "createChildDevices()... device=${device}"
	
	(1..2).each { endPoint ->
		if (!findChildByEndPoint(endPoint)) {			
			def dni = "${getChildDeviceNetworkId(endPoint)}"
			
			addChildSwitch(dni, endPoint)
			childUpdated(dni)
		}
	}
}

private addChildSwitch(dni, endPoint) {
	logDebug "Creating SW${endPoint} Child Device  device=${device}"
	try {
		def newChild = addChildDevice("Leza", "Aqara LLKZMK11LM Child Switch", dni, null, 
			[
				completedSetup: true,
				label: "${device.displayName}-SW${endPoint}",
				isComponent: false
			]
		)
		//newChild.sendEvent(name:"switch", value:"off")
	} catch(e) {
	   logTrace "addChildSwitch failed: ${e}"
	}
	
}


private updateHealthCheckInterval() {
	logDebug "updateHealthCheckInterval().."
	
	// Device wakes up every 1 hours, this interval allows us to miss one wakeup notification before marking offline
	def minReportingInterval = (1 * 60 * 60)
	
	if (state.minReportingInterval != minReportingInterval) {
		state.minReportingInterval = minReportingInterval
		logDebug "Configured health checkInterval when updated()"
		
		// Set the Health Check interval so that it can be skipped twice plus 2 minutes.
		def checkInterval = ((minReportingInterval * 2) + (2 * 60))
		sendEvent(name: "checkInterval", value: checkInterval, displayed: false, data: [protocol: "zigbee", hubHardwareId: device.hub.hardwareID])
	}
}

def childUpdated(dni) {
	logDebug "childUpdated(${dni})"
	
	def child = findChildByDeviceNetworkId(dni)
	def endPoint = getEndPoint(dni)
	def nameAttr = "sw${endPoint}Name"
	logDebug "${child.displayName} vs ${device.currentValue(nameAttr)}"
	if (child && "${child.displayName}" != "${device.currentValue(nameAttr)}") {
		sendEvent(name: nameAttr, value: child.displayName, displayed: false)
	}
}

def ping() {
	logDebug "ping()..."
	
	return zigbee.onOffRefresh() + zigbee.onOffConfig()
}

def on() {
	logDebug "on()..."
	sw1On()
	sw2On()
}

def off() {
	logDebug "off()..."
	sw1Off()
	sw2Off()
}

def sw1On()  { childOn(getChildDeviceNetworkId(1)) }
def sw2On()  { childOn(getChildDeviceNetworkId(2)) }
def sw1Off() { childOff(getChildDeviceNetworkId(1)) }
def sw2Off() { childOff(getChildDeviceNetworkId(2)) }


def childOn(dni) {
    
	def endPoint = getEndPoint(dni)
	
	logDebug "Turn On: dni=${dni} endPoint=${endPoint}..."
	
	if ( (endPoint == 1) || (endPoint == 2) ) {
		//zigbee.on()
		def actions = [new physicalgraph.device.HubAction("st cmd 0x${device.deviceNetworkId} 0x0${endPoint} 0x0006 0x01 {}")]    
		sendHubCommand(actions)	
	}
	else {
		logTrace "childOn failed: Invalid endpoint: dni=${dni} endPoint=(${endPoint})"
	}
}


def childOff(dni) {
	
	def endPoint = getEndPoint(dni)
	
	logDebug "Turn Off: dni=${dni} endPoint=${endPoint}..."

	if ( (endPoint == 1) || (endPoint == 2) ) {
		//zigbee.off()
		def actions = [new physicalgraph.device.HubAction("st cmd 0x${device.deviceNetworkId} 0x0${endPoint} 0x0006 0x00 {}")]    
		sendHubCommand(actions)	
	}
	else {
		logTrace "childOn failed: Invalid endpoint: dni=${dni} endPoint=(${endPoint})"
	}
}

def refresh() {
	logDebug "refresh()..."	
	def Cmds = zigbee.readAttribute(0x0001, 0x0000, [destEndpoint: 0x01]) +		// voltage
			   zigbee.readAttribute(0x0002, 0x0000, [destEndpoint: 0x01]) +		// temperature
			   zigbee.readAttribute(0x0006, 0x0000, [destEndpoint: 0x01]) +		// switch 1 state
			   zigbee.readAttribute(0x0006, 0x0000, [destEndpoint: 0x02]) +		// switch 2 state
			   zigbee.readAttribute(0x000C, 0x0055, [destEndpoint: 0x03])		// power
	return Cmds
}

def childRefresh(dni) {
	logDebug "childRefresh(): child(${dni})"
	
	def endPoint = getEndPoint(dni)
	
	def Cmds = zigbee.readAttribute(0x0001, 0x0000, [destEndpoint: 0x01]) +		// voltage
			   zigbee.readAttribute(0x0002, 0x0000, [destEndpoint: 0x01]) +		// temperature
			   zigbee.readAttribute(0x0006, 0x0000, [destEndpoint: endPoint])	// switch state
	
	def actions = []
	
    Cmds?.each {
		actions << new physicalgraph.device.HubAction(it)
	}
	sendHubCommand(actions, 100)
	return []
}

// Parse incoming device messages to generate events
def parse(String description) {
	logDebug "parse(): description is $description"
	def cluster = zigbee.parseDescriptionAsMap(description)
	logDebug "parse: descMap is $cluster"
	
	if (description?.startsWith("read attr -")) {		
		// Switch state
		if ((cluster.clusterInt == 0x0006) && (cluster.attrInt == 0x0000)) {
			if(cluster.endpoint == "01") {
				state.sw1 = (cluster.value == "01" ? "on" : "off")
				executeSendEvent(findChildByEndPoint(1), createEventMap("switch", state.sw1))
				executeSendEvent(null, createEventMap("sw1Switch", state.sw1))
				executeSendEvent(null, createEventMap("switch", ((state.sw1 == "on") || (state.sw2 == "on")) ? "on" : "off"))
			}
        	else if (cluster.endpoint == "02") {
				state.sw2 = (cluster.value == "01" ? "on" : "off")
				executeSendEvent(findChildByEndPoint(2), createEventMap("switch", state.sw2))
				executeSendEvent(null, createEventMap("sw2Switch", state.sw2))
				executeSendEvent(null, createEventMap("switch", ((state.sw1 == "on") || (state.sw2 == "on")) ? "on" : "off"))
			}
		}
		// Voltage
		else if (cluster.clusterInt == 0x0001 && cluster.attrInt == 0x000) {
			if (cluster.endpoint == "01") {
				def value = (int) (Integer.parseInt(cluster.value, 16) / 10)
				executeSendEvent(null, createEventMap("voltage", value, null, "V"))
				executeSendEvent(findChildByEndPoint(1), createEventMap("voltage", value, null, "V"))
				executeSendEvent(findChildByEndPoint(2), createEventMap("voltage", value, null, "V"))
			}
		}
		// Temperature
		else if (cluster.clusterInt == 0x0002 && cluster.attrInt == 0x000) {
			if (cluster.endpoint == "01") {
				def value = Integer.parseInt(cluster.value, 16)
				if (value > 127)	value = value - 256
				executeSendEvent(null, createEventMap("temperature", value, null, "C"))
				executeSendEvent(findChildByEndPoint(1), createEventMap("temperature", value, null, "C"))
				executeSendEvent(findChildByEndPoint(2), createEventMap("temperature", value, null, "C"))
			}
		}
		// Power meter
		else if ((cluster.clusterInt == 0x000C) && (cluster.attrInt == 0x0055)) {
			if (cluster.endpoint == "03") {
				def value = Float.intBitsToFloat(Long.parseLong(cluster.value, 16).intValue())
				executeSendEvent(null, createEventMap("power", roundTwoPlaces(value), null, "W"))
			}
		}
	}
	
	if (description?.startsWith("catchall:")) {
		if ((cluster.clusterInt == 0x0000) && (cluster.attrInt == 0xFF01)) {
			Map key = [:]
			int i = 4
			int j
			
			// get keys
			while (i < cluster.data.size()) {
				// save start index
				j = i
			
				// get key type
				key.type = Integer.parseInt(cluster.data[i], 16)
				if      (key.type == Key_TEMPERATURE())		key.name = "temperature"        	
				else if (key.type == Key_RSSI())			key.name = "RSSI" 
				else if (key.type == Key_SWITCH_1())		key.name = "switch1" 
				else if (key.type == Key_SWITCH_2())		key.name = "switch2" 
				else if (key.type == Key_ENERGY_METER())	key.name = "energy" 
				else if (key.type == Key_POWER_METER())		key.name = "power" 
				else										key.name = "unknown (" + cluster.data[i] + ")"
			
				// get key value
				i++
				key.datatype = Integer.parseInt(cluster.data[i++], 16)
				if (key.datatype == ZB_Data_BOOLEAN()) {
					key.value = ((cluster.data[i] == "01") ? "on" : "off")
				}
				else if (key.datatype == ZB_Data_UINT8()) {
					key.value = Integer.parseInt(cluster.data[i], 16)
				}
				else if (key.datatype == ZB_Data_UINT16()) {
					key.value = Integer.parseInt(cluster.data[i+1] + cluster.data[i], 16)
					i += 1
				}
				else if (key.datatype == ZB_Data_UINT64()) {
					key.value = Long.parseLong(cluster.data[i+7] + cluster.data[i+6] + cluster.data[i+5] + cluster.data[i+4] +
											   cluster.data[i+3] + cluster.data[i+2] + cluster.data[i+1] + cluster.data[i], 16)
					i += 7
				}
				else if (key.datatype == ZB_Data_INT8()) {
					key.value = Integer.parseInt(cluster.data[i], 16)
					if (key.value > 127) {
						key.value = key.value - 256
					}
				}
				else if (key.datatype == ZB_Data_FLOAT4()) {
					key.value = Float.intBitsToFloat(Long.parseLong(cluster.data[i+3] + cluster.data[i+2] +
																	cluster.data[i+1] + cluster.data[i], 16).intValue())
					i += 3
				}
				logDebug "index: $j, key: $key.name, value: $key.value"
			
				// send event
				if (key.type == Key_TEMPERATURE()) {
					executeSendEvent(null, createEventMap("temperature", key.value, null, "C"))
					executeSendEvent(findChildByEndPoint(1), createEventMap("temperature", key.value, null, "C"))
					executeSendEvent(findChildByEndPoint(2), createEventMap("temperature", key.value, null, "C"))
				}
				else if (key.type == Key_SWITCH_1()) {
					state.sw1 = key.value
					executeSendEvent(findChildByEndPoint(1), createEventMap("switch", state.sw1))
					executeSendEvent(null, createEventMap("sw1Switch", state.sw1))
					executeSendEvent(null, createEventMap("switch", ((state.sw1 == "on") || (state.sw2 == "on")) ? "on" : "off"))
				}
				else if (key.type == Key_SWITCH_2()) {
					state.sw2 = key.value
					executeSendEvent(findChildByEndPoint(2), createEventMap("switch", state.sw2))
					executeSendEvent(null, createEventMap("sw2Switch", state.sw2))
					executeSendEvent(null, createEventMap("switch", ((state.sw1 == "on") || (state.sw2 == "on")) ? "on" : "off"))
				}
				else if (key.type == Key_ENERGY_METER()) {
					executeSendEvent(null, createEventMap("energy", roundTwoPlaces(key.value), null, "kWh"))
				}
				else if (key.type == Key_POWER_METER()) {
					executeSendEvent(null, createEventMap("power", roundTwoPlaces(key.value), null, "W"))
				}
			
				i++
			}
		}
	}
    
	// send event for heartbeat
	def now = new Date().format("dd-MM-yyyy HH:mm:ss", location.timeZone)
	sendEvent(name: "lastCheckin", value: now, displayed: false)
	executeSendEvent(findChildByEndPoint(1), createEventMap("lastCheckin", now))
	executeSendEvent(findChildByEndPoint(2), createEventMap("lastCheckin", now))
}

private executeSendEvent(child, evt) {
	
	if (evt.displayed == null)	evt.displayed = (getAttrVal(evt.name, child) != evt.value)

	logDebug "executeSendEvent(): child=${child} evt=${evt} device=${device}"
    
	if (evt) {
		if (child) {
			if (evt.descriptionText) {
				evt.descriptionText = evt.descriptionText.replace(device.displayName, child.displayName)
			}
			child.sendEvent(evt)						
		}
		else {
            sendEvent(evt)
		}		
	}
}

private createEventMap(name, value, displayed=null, unit=null) {	
	def eventMap = [
		name: name,
		value: value,
		displayed: displayed,
		isStateChange: true,
		descriptionText: "${device.displayName} - ${name} is ${value}"
	]
	
	if (unit) {
		eventMap.unit = unit
		eventMap.descriptionText = "${eventMap.descriptionText} ${unit}"
	}
	return eventMap
}

private getAttrVal(attrName, child=null) {
	//logDebug "getAttrVal(): attrName=${attrName} child=${child}"
	
	try {
		if (child) {
			return child?.currentValue("${attrName}")
		}
		else {
			return device?.currentValue("${attrName}")
		}
	}
	catch (ex) {
		logTrace "$ex"
		return null
	}
}

private findChildByEndPoint(endPoint) {
	def dni = "${getChildDeviceNetworkId(endPoint)}"
	return findChildByDeviceNetworkId(dni)
}

private findChildByDeviceNetworkId(dni) {
	return childDevices?.find { it.deviceNetworkId == dni }
}

private getEndPoint(childDeviceNetworkId) {
	return safeToInt("${childDeviceNetworkId}".reverse().take(1))
}

private getChildDeviceNetworkId(endPoint) {
	return "${device.deviceNetworkId}-SW${endPoint}"
}

private safeToInt(val, defaultVal=0) {
	return "${val}"?.isInteger() ? "${val}".toInteger() : defaultVal
}

private safeToDec(val, defaultVal=0) {
	return "${val}"?.isBigDecimal() ? "${val}".toBigDecimal() : defaultVal
}

private roundTwoPlaces(val) {
	return Math.round(safeToDec(val) * 100) / 100
}

private isDuplicateCommand(lastExecuted, allowedMil) {
	!lastExecuted ? false : (lastExecuted + allowedMil > new Date().time) 
}

private logDebug(msg) {
	if (settings?.debugOutput != false) {
		log.debug "$msg"
	}
}

private logTrace (msg) {
	log.error "$msg"
}
