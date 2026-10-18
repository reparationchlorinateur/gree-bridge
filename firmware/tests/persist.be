# Test mock of Tasmota's persist: an instance whose attribute writes go through setmember,
# like the real one (persist.x = v is then readable with persist.find("x"))
class Persist
  var _d, saves
  def init() self._d = {} self.saves = 0 end
  def find(k, d) return self._d.contains(k) ? self._d[k] : d end
  def has(k) return self._d.contains(k) end
  def member(k) return self._d.find(k) end
  def setmember(k, v) self._d[k] = v end
  def save() self.saves += 1 print("  [persist.save]") end
end
return Persist()
