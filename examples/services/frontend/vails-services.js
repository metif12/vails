// service: clipboard 0.1.0 - system clipboard text
(function () {
  var v = window.vails = window.vails || {};
  var ns = v.clipboard = v.clipboard || {};
  ns.read_text = function (params) { return v.call("clipboard.read_text", params || ""); };
  ns.write_text = function (params) { return v.call("clipboard.write_text", params || ""); };
}());
// service: opener 0.1.0 - open a path or URL in the default application
(function () {
  var v = window.vails = window.vails || {};
  var ns = v.opener = v.opener || {};
  ns.open_url = function (params) { return v.call("opener.open_url", params || ""); };
  ns.open_path = function (params) { return v.call("opener.open_path", params || ""); };
}());
// service: notification 0.1.0 - short native notification
(function () {
  var v = window.vails = window.vails || {};
  var ns = v.notification = v.notification || {};
  ns.notify = function (params) { return v.call("notification.notify", params || ""); };
  ns.is_supported = function (params) { return v.call("notification.is_supported", params || ""); };
}());
// service: menu 0.1.0 - native popup menus
(function () {
  var v = window.vails = window.vails || {};
  var ns = v.menu = v.menu || {};
  ns.popup = function (params) { return v.call("menu.popup", params || ""); };
  ns.close = function (params) { return v.call("menu.close", params || ""); };
  ns.set_menu = function (params) { return v.call("menu.set_menu", params || ""); };
}());
// service: dialog 0.1.0 - native file and message dialogs
(function () {
  var v = window.vails = window.vails || {};
  var ns = v.dialog = v.dialog || {};
  ns.open = function (params) { return v.call("dialog.open", params || ""); };
  ns.save = function (params) { return v.call("dialog.save", params || ""); };
  ns.message = function (params) { return v.call("dialog.message", params || ""); };
}());
// service: tray 0.1.0 - system tray icon
(function () {
  var v = window.vails = window.vails || {};
  var ns = v.tray = v.tray || {};
  ns.set = function (params) { return v.call("tray.set", params || ""); };
  ns.destroy = function (params) { return v.call("tray.destroy", params || ""); };
  ns.set_menu = function (params) { return v.call("tray.set_menu", params || ""); };
}());
// service: os_info 0.1.0 - host os, arch and paths
(function () {
  var v = window.vails = window.vails || {};
  var ns = v.os_info = v.os_info || {};
  ns.get = function (params) { return v.call("os_info.get", params || ""); };
}());
