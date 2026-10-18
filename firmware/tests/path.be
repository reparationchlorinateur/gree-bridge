# Test mock of Tasmota's path module, on top of the host's os module
import os
var path = module("path")
path.exists = def (p) return os.path.exists(p) end
path.remove = def (p) return os.remove(p) end
path.rename = def (a, b)
  var f = open(a, "r") var s = f.read() f.close()
  var g = open(b, "w") g.write(s) g.close()
  os.remove(a)
  return true
end
return path
