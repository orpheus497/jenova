## Script function and purpose: the minimum of libdbus-1 that `tray.nim` speaks,
## not a general binding. GTK4 dropped `libappindicator` and owlkettle has no
## tray, so a tray icon is a protocol rather than a widget: a D-Bus object
## implementing `org.kde.StatusNotifierItem`, registered with the watcher, whose
## menu is a second object implementing `com.canonical.dbusmenu`.
##
## libdbus rather than GDBus, which ships with GTK4 and would add no dependency:
## GDBus registers objects through introspection XML and `GVariant`, so using it
## means shipping a parser or hand-building variants through a second C API. The
## smaller API keeps the marshalling visible, which matters for a protocol where
## a wrong signature yields a silently absent icon rather than an error.

{.passC: gorge("pkg-config --cflags dbus-1").}
{.passL: gorge("pkg-config --libs dbus-1").}

# Action purpose: bound through the real header rather than by mirroring the
# ABI in Nim, so a struct whose layout moves is a C compile error instead of a
# wrong pointer. The `dummy` and `pad` fields below are libdbus's own names for
# opaque space and must keep their size, not their meaning.
{.push header: "<dbus/dbus.h>".}

type
  DBusConnection* {.importc: "DBusConnection".} = object
  DBusMessage* {.importc: "DBusMessage".} = object
  DBusError* {.importc: "DBusError", bycopy.} = object
    name* {.importc: "name".}: cstring
    message* {.importc: "message".}: cstring

  DBusMessageIter* {.importc: "DBusMessageIter", bycopy.} = object
    dummy1: pointer
    dummy2: pointer
    dummy3: uint32
    dummy4: cint
    dummy5: cint
    dummy6: cint
    dummy7: cint
    dummy8: cint
    dummy9: cint
    dummy10: cint
    dummy11: cint
    pad1: cint
    pad2: pointer
    pad3: pointer

  DBusBusType* {.importc: "DBusBusType".} = distinct cint
  DBusHandlerResult* {.importc: "DBusHandlerResult".} = distinct cint

  DBusObjectPathVTable* {.importc: "DBusObjectPathVTable", bycopy.} = object
    unregister_function*: pointer
    message_function*: pointer
    dbus_internal_pad1*: pointer
    dbus_internal_pad2*: pointer
    dbus_internal_pad3*: pointer
    dbus_internal_pad4*: pointer

var
  DBUS_BUS_SESSION* {.importc: "DBUS_BUS_SESSION".}: DBusBusType
  DBUS_HANDLER_RESULT_HANDLED* {.importc: "DBUS_HANDLER_RESULT_HANDLED".}: DBusHandlerResult
  DBUS_HANDLER_RESULT_NOT_YET_HANDLED* {.importc: "DBUS_HANDLER_RESULT_NOT_YET_HANDLED".}: DBusHandlerResult

proc dbus_error_init*(err: ptr DBusError) {.importc.}
proc dbus_error_is_set*(err: ptr DBusError): cint {.importc.}
proc dbus_error_free*(err: ptr DBusError) {.importc.}

proc dbus_bus_get*(t: DBusBusType, err: ptr DBusError): ptr DBusConnection {.importc.}
proc dbus_bus_request_name*(conn: ptr DBusConnection, name: cstring,
                            flags: cuint, err: ptr DBusError): cint {.importc.}
proc dbus_connection_set_exit_on_disconnect*(conn: ptr DBusConnection,
                                             exitOnDisconnect: cint) {.importc.}
proc dbus_connection_register_object_path*(conn: ptr DBusConnection,
                                           path: cstring,
                                           vtable: ptr DBusObjectPathVTable,
                                           userData: pointer): cint {.importc.}
proc dbus_connection_send*(conn: ptr DBusConnection, msg: ptr DBusMessage,
                           serial: ptr cuint): cint {.importc.}
proc dbus_connection_flush*(conn: ptr DBusConnection) {.importc.}
proc dbus_connection_read_write_dispatch*(conn: ptr DBusConnection,
                                          timeoutMs: cint): cint {.importc.}
proc dbus_connection_send_with_reply_and_block*(conn: ptr DBusConnection,
                                                msg: ptr DBusMessage,
                                                timeoutMs: cint,
                                                err: ptr DBusError): ptr DBusMessage {.importc.}

proc dbus_message_new_method_call*(dest, path, iface, meth: cstring): ptr DBusMessage {.importc.}
proc dbus_message_new_method_return*(call: ptr DBusMessage): ptr DBusMessage {.importc.}
proc dbus_message_new_signal*(path, iface, name: cstring): ptr DBusMessage {.importc.}
proc dbus_message_new_error*(call: ptr DBusMessage, name, msg: cstring): ptr DBusMessage {.importc.}
proc dbus_message_unref*(msg: ptr DBusMessage) {.importc.}
proc dbus_message_is_method_call*(msg: ptr DBusMessage, iface, meth: cstring): cint {.importc.}
proc dbus_message_get_interface*(msg: ptr DBusMessage): cstring {.importc.}
proc dbus_message_get_member*(msg: ptr DBusMessage): cstring {.importc.}

proc dbus_message_iter_init*(msg: ptr DBusMessage, iter: ptr DBusMessageIter): cint {.importc.}
proc dbus_message_iter_init_append*(msg: ptr DBusMessage, iter: ptr DBusMessageIter) {.importc.}
proc dbus_message_iter_append_basic*(iter: ptr DBusMessageIter, t: cint,
                                     value: pointer): cint {.importc.}
proc dbus_message_iter_open_container*(iter: ptr DBusMessageIter, t: cint,
                                       contained: cstring,
                                       sub: ptr DBusMessageIter): cint {.importc.}
proc dbus_message_iter_close_container*(iter, sub: ptr DBusMessageIter): cint {.importc.}
proc dbus_message_iter_get_arg_type*(iter: ptr DBusMessageIter): cint {.importc.}
proc dbus_message_iter_get_basic*(iter: ptr DBusMessageIter, value: pointer) {.importc.}
proc dbus_message_iter_next*(iter: ptr DBusMessageIter): cint {.importc.}

{.pop.}

## Action purpose: D-Bus type codes are the ASCII characters of the signature
## language, so they are written as characters rather than as integers — `'s'`
## here reads the same as `"s"` does in a signature string.
const
  TypeString* = cint(ord('s'))
  TypeInt32* = cint(ord('i'))
  TypeUInt32* = cint(ord('u'))
  TypeBoolean* = cint(ord('b'))
  TypeVariant* = cint(ord('v'))
  TypeArray* = cint(ord('a'))
  TypeStruct* = cint(ord('r'))
  TypeDictEntry* = cint(ord('e'))
  TypeObjectPath* = cint(ord('o'))
  TypeInvalid* = cint(0)

  NameFlagReplaceExisting* = cuint(0x2)

## Function purpose: the shape every `org.freedesktop.DBus.Properties.Get` reply
## takes. Written once because the open/append/close triple is easy to get
## subtly wrong, and a malformed reply loses the tray without any error.
proc appendVariantString*(iter: ptr DBusMessageIter, value: string) =
  var sub: DBusMessageIter
  discard dbus_message_iter_open_container(iter, TypeVariant, "s", addr sub)
  var cs = value.cstring
  discard dbus_message_iter_append_basic(addr sub, TypeString, addr cs)
  discard dbus_message_iter_close_container(iter, addr sub)

## Function purpose: the same triple for the boolean properties, spelled out
## rather than generic because the container signature differs per type.
proc appendVariantBool*(iter: ptr DBusMessageIter, value: bool) =
  var sub: DBusMessageIter
  discard dbus_message_iter_open_container(iter, TypeVariant, "b", addr sub)
  var v = cint(ord(value))
  discard dbus_message_iter_append_basic(addr sub, TypeBoolean, addr v)
  discard dbus_message_iter_close_container(iter, addr sub)

## Function purpose: the triple again for `u`, which the menu revision counter
## and the item's window id are sent as.
proc appendVariantUint32*(iter: ptr DBusMessageIter, value: uint32) =
  var sub: DBusMessageIter
  discard dbus_message_iter_open_container(iter, TypeVariant, "u", addr sub)
  var v = cuint(value)
  discard dbus_message_iter_append_basic(addr sub, TypeUInt32, addr v)
  discard dbus_message_iter_close_container(iter, addr sub)

## Function purpose: a bare string argument rather than a variant — the local
## `cstring` exists because `append_basic` takes the address of the pointer.
proc appendString*(iter: ptr DBusMessageIter, value: string) =
  var cs = value.cstring
  discard dbus_message_iter_append_basic(iter, TypeString, addr cs)

## Function purpose: the same for `i`, which carries the menu item ids.
proc appendInt32*(iter: ptr DBusMessageIter, value: int32) =
  var v = value
  discard dbus_message_iter_append_basic(iter, TypeInt32, addr v)

## Function purpose: callers pick apart method calls whose signature they
## already know, so a wrong type means a malformed peer rather than a case to
## handle. Answering "" lets them reply with an error instead of crashing.
proc readString*(iter: ptr DBusMessageIter): string =
  if dbus_message_iter_get_arg_type(iter) != TypeString:
    return ""
  var cs: cstring
  dbus_message_iter_get_basic(iter, addr cs)
  if cs.isNil: "" else: $cs

## Function purpose: the same contract for `i`, where zero is the no-argument
## answer — safe here because no menu item is numbered zero.
proc readInt32*(iter: ptr DBusMessageIter): int32 =
  if dbus_message_iter_get_arg_type(iter) != TypeInt32:
    return 0
  var v: int32
  dbus_message_iter_get_basic(iter, addr v)
  v
