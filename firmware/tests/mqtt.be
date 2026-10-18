var mqtt = module("mqtt")
mqtt.publish = def (topic, payload, retain, start, len, loglevel)
  if start != nil raise "argument_error", "start and len are not allowed with string payloads" end
  PUBS.push([topic, payload, retain])
end
mqtt.connected = def () return MQTT_UP end
return mqtt
