# Test mock of Tasmota's gpio module: the pin level comes from SIGNAL(pin, t) at the mock clock
# MOCK_T (microseconds), which advances a little on every read, like a real polling loop.
var gpio = module("gpio")
gpio.INPUT = 1
gpio.pin_mode = def (p, m) GPIO_MODES[p] = m end
gpio.digital_read = def (p) MOCK_T += 3 return SIGNAL(p, MOCK_T) end
return gpio
