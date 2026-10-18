# Test mock of Tasmota's webserver module: collects what a page sends
var webserver = module("webserver")
webserver.HTTP_GET = 1
webserver.HTTP_POST = 2
webserver.BUTTON_MAIN = 0
webserver.check_privileged_access = def () return true end
webserver.content_start = def (t) WEB.push("<start " + t + ">") end
webserver.content_send_style = def () end
webserver.content_send = def (s) WEB.push(s) end
webserver.content_button = def (b) end
webserver.content_stop = def () WEB.push("<stop>") end
webserver.html_escape = def (s) return s end
webserver.has_arg = def (a) return WEB_ARGS.contains(a) end
webserver.arg = def (a) return WEB_ARGS[a] end
webserver.redirect = def (u) WEB.push("<redirect " + u + ">") end
webserver.on = def (p, f, m) WEB_ROUTES[p + str(m)] = f end
return webserver
