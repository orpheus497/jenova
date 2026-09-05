## Script function and purpose: the tray icon, as a StatusNotifierItem published
## on D-Bus. There is no widget call for this — GTK4 dropped the old tray library
## and owlkettle has none, so a modern desktop takes an icon as a D-Bus object
## registered with a watcher, with the menu as a second object.
##
## The connection is dispatched from a GTK main-loop timeout rather than a
## thread, with a zero timeout so it never blocks. That means menu callbacks run
## on the same thread as the widgets and there is no locking question at all —
## which matters, because a tray owning a separate execution context is how a
## tray and a supervisor come to disagree about what is running.
##
## Scope: the item properties a watcher reads, a flat menu, and the signals that
## make a panel re-read. No submenus and no icon pixmaps — an icon name is used.
## A flat menu is the whole surface here rather than a subset of a larger one.

import std/os
import ./dbus

type
  TrayItemKind* = enum
    tiAction
    tiSeparator

  TrayItem* = object
    kind*: TrayItemKind
    id*: int32
    label*: string
    action*: string

  TrayStatus* = enum
    tsPassive = "Passive"
    tsActive = "Active"
    tsAttention = "NeedsAttention"

  TrayCallback* = proc (action: string) {.closure.}

  Tray* = ref object
    conn*: ptr DBusConnection
    items*: seq[TrayItem]
    status*: TrayStatus
    title*: string
    iconName*: string
    tooltip*: string
    onAction*: TrayCallback
    registered*: bool
    revision*: uint32

const
  ItemPath = "/StatusNotifierItem"
  MenuPath = "/MenuBar"
  ItemIface = "org.kde.StatusNotifierItem"
  MenuIface = "com.canonical.dbusmenu"
  PropIface = "org.freedesktop.DBus.Properties"
  WatcherName = "org.kde.StatusNotifierWatcher"
  WatcherPath = "/StatusNotifierWatcher"
  ## The dbusmenu protocol revision this object implements. A panel reads it to
  ## decide whether the object is a menu at all.
  DbusMenuVersion = 3'u32

## Action purpose: one tray per process, in module state. The vtable hands
## callbacks a raw pointer, and threading a reference through it means pinning it
## against the collector for the process lifetime — and the bus name is unique
## per process anyway, so there is no generality to preserve.
var theTray: Tray

## Function purpose: a watcher reads these to decide whether to show the icon at
## all, so an unanswered property is an invisible tray rather than an error.
proc replyItemProperty(msg: ptr DBusMessage, prop: string): ptr DBusMessage =
  result = dbus_message_new_method_return(msg)
  var iter: DBusMessageIter
  dbus_message_iter_init_append(result, addr iter)
  case prop
  of "Category": appendVariantString(addr iter, "ApplicationStatus")
  of "Id": appendVariantString(addr iter, "jenova")
  of "Title": appendVariantString(addr iter, theTray.title)
  of "Status": appendVariantString(addr iter, $theTray.status)
  of "IconName": appendVariantString(addr iter, theTray.iconName)
  of "AttentionIconName": appendVariantString(addr iter, "")
  of "OverlayIconName": appendVariantString(addr iter, "")
  of "ToolTip":
    # Icon name, pixmap array, title, description — the pixmap array is empty
    # because an icon name is used instead.
    var v, st, pix: DBusMessageIter
    discard dbus_message_iter_open_container(addr iter, TypeVariant,
                                             "(sa(iiay)ss)", addr v)
    discard dbus_message_iter_open_container(addr v, TypeStruct, nil, addr st)
    appendString(addr st, theTray.iconName)
    discard dbus_message_iter_open_container(addr st, TypeArray, "(iiay)", addr pix)
    discard dbus_message_iter_close_container(addr st, addr pix)
    appendString(addr st, theTray.title)
    appendString(addr st, theTray.tooltip)
    discard dbus_message_iter_close_container(addr v, addr st)
    discard dbus_message_iter_close_container(addr iter, addr v)
  of "ItemIsMenu":
    # A left click opens the menu rather than emitting an activate: there is no
    # primary action here, so the menu is the whole interface.
    appendVariantBool(addr iter, true)
  of "Menu":
    var sub: DBusMessageIter
    discard dbus_message_iter_open_container(addr iter, TypeVariant, "o", addr sub)
    var cs = MenuPath.cstring
    discard dbus_message_iter_append_basic(addr sub, TypeObjectPath, addr cs)
    discard dbus_message_iter_close_container(addr iter, addr sub)
  else:
    appendVariantString(addr iter, "")

## Function purpose: separators and actions differ only in their properties,
## because dbusmenu has no separate item type on the wire.
proc appendItemProps(iter: ptr DBusMessageIter, item: TrayItem) =
  var props, entry, val: DBusMessageIter
  discard dbus_message_iter_open_container(iter, TypeArray, "{sv}", addr props)

  proc putString(key, value: string) =
    discard dbus_message_iter_open_container(addr props, TypeDictEntry, nil, addr entry)
    appendString(addr entry, key)
    appendVariantString(addr entry, value)
    discard dbus_message_iter_close_container(addr props, addr entry)

  proc putBool(key: string, value: bool) =
    discard dbus_message_iter_open_container(addr props, TypeDictEntry, nil, addr entry)
    appendString(addr entry, key)
    appendVariantBool(addr entry, value)
    discard dbus_message_iter_close_container(addr props, addr entry)

  case item.kind
  of tiSeparator:
    putString("type", "separator")
  of tiAction:
    putString("label", item.label)
    putBool("enabled", true)
    putBool("visible", true)
  discard val
  discard dbus_message_iter_close_container(iter, addr props)

## Function purpose: the nesting is the fiddly part — an item is a struct of id,
## a property dictionary and an array of variants each wrapping a child, with the
## root carrying the submenu marker and every real item an empty child array.
## Getting it wrong opens an empty menu rather than raising, which is why this is
## one function and not inlined at the call site.
proc appendLayout(iter: ptr DBusMessageIter) =
  var root, rootProps, entry, kids: DBusMessageIter
  discard dbus_message_iter_open_container(iter, TypeStruct, nil, addr root)
  appendInt32(addr root, 0)

  discard dbus_message_iter_open_container(addr root, TypeArray, "{sv}", addr rootProps)
  discard dbus_message_iter_open_container(addr rootProps, TypeDictEntry, nil, addr entry)
  appendString(addr entry, "children-display")
  appendVariantString(addr entry, "submenu")
  discard dbus_message_iter_close_container(addr rootProps, addr entry)
  discard dbus_message_iter_close_container(addr root, addr rootProps)

  discard dbus_message_iter_open_container(addr root, TypeArray, "v", addr kids)
  for item in theTray.items:
    var kidVar, kidStruct, emptyKids: DBusMessageIter
    discard dbus_message_iter_open_container(addr kids, TypeVariant,
                                             "(ia{sv}av)", addr kidVar)
    discard dbus_message_iter_open_container(addr kidVar, TypeStruct, nil, addr kidStruct)
    appendInt32(addr kidStruct, item.id)
    appendItemProps(addr kidStruct, item)
    discard dbus_message_iter_open_container(addr kidStruct, TypeArray, "v", addr emptyKids)
    discard dbus_message_iter_close_container(addr kidStruct, addr emptyKids)
    discard dbus_message_iter_close_container(addr kidVar, addr kidStruct)
    discard dbus_message_iter_close_container(addr kids, addr kidVar)
  discard dbus_message_iter_close_container(addr root, addr kids)

  discard dbus_message_iter_close_container(iter, addr root)

## Function purpose: sends and flushes together, because the dispatch loop only
## runs on the next timer tick and an unflushed signal would arrive late.
proc send(conn: ptr DBusConnection, msg: ptr DBusMessage) =
  discard dbus_connection_send(conn, msg, nil)
  dbus_connection_flush(conn)
  dbus_message_unref(msg)

## Function purpose: the property reads a watcher performs and the click methods
## it forwards, in one place so an unhandled member is visibly unhandled.
proc itemHandler(conn: ptr DBusConnection, msg: ptr DBusMessage,
                 userData: pointer): DBusHandlerResult {.cdecl.} =
  if dbus_message_is_method_call(msg, PropIface, "Get") != 0:
    var iter: DBusMessageIter
    var prop = ""
    if dbus_message_iter_init(msg, addr iter) != 0:
      discard readString(addr iter)          # interface name, unused
      if dbus_message_iter_next(addr iter) != 0:
        prop = readString(addr iter)
    send(conn, replyItemProperty(msg, prop))
    return DBUS_HANDLER_RESULT_HANDLED

  # Action purpose: some watchers call the bulk property read exclusively rather
  # than falling back to the single one, so leaving it unanswered is an icon that
  # never appears on a whole desktop environment.
  if dbus_message_is_method_call(msg, PropIface, "GetAll") != 0:
    let reply = dbus_message_new_method_return(msg)
    var iter, dict, entry: DBusMessageIter
    dbus_message_iter_init_append(reply, addr iter)
    discard dbus_message_iter_open_container(addr iter, TypeArray, "{sv}", addr dict)
    for key in ["Category", "Id", "Title", "Status", "IconName", "ItemIsMenu"]:
      discard dbus_message_iter_open_container(addr dict, TypeDictEntry, nil, addr entry)
      appendString(addr entry, key)
      case key
      of "Category": appendVariantString(addr entry, "ApplicationStatus")
      of "Id": appendVariantString(addr entry, "jenova")
      of "Title": appendVariantString(addr entry, theTray.title)
      of "Status": appendVariantString(addr entry, $theTray.status)
      of "IconName": appendVariantString(addr entry, theTray.iconName)
      of "ItemIsMenu": appendVariantBool(addr entry, true)
      else: appendVariantString(addr entry, "")
      discard dbus_message_iter_close_container(addr dict, addr entry)
    # An object path is its own type, so it cannot go through the string helper.
    discard dbus_message_iter_open_container(addr dict, TypeDictEntry, nil, addr entry)
    appendString(addr entry, "Menu")
    var v: DBusMessageIter
    discard dbus_message_iter_open_container(addr entry, TypeVariant, "o", addr v)
    var cs = MenuPath.cstring
    discard dbus_message_iter_append_basic(addr v, TypeObjectPath, addr cs)
    discard dbus_message_iter_close_container(addr entry, addr v)
    discard dbus_message_iter_close_container(addr dict, addr entry)
    discard dbus_message_iter_close_container(addr iter, addr dict)
    send(conn, reply)
    return DBUS_HANDLER_RESULT_HANDLED

  for m in ["Activate", "SecondaryActivate", "Scroll", "ContextMenu"]:
    if dbus_message_is_method_call(msg, ItemIface, m.cstring) != 0:
      send(conn, dbus_message_new_method_return(msg))
      return DBUS_HANDLER_RESULT_HANDLED

  DBUS_HANDLER_RESULT_NOT_YET_HANDLED

## Function purpose: the dbusmenu side of the same protocol, kept separate
## because a panel addresses it as a distinct object.
proc menuHandler(conn: ptr DBusConnection, msg: ptr DBusMessage,
                 userData: pointer): DBusHandlerResult {.cdecl.} =
  if dbus_message_is_method_call(msg, MenuIface, "GetLayout") != 0:
    let reply = dbus_message_new_method_return(msg)
    var iter: DBusMessageIter
    dbus_message_iter_init_append(reply, addr iter)
    var rev = cuint(theTray.revision)
    discard dbus_message_iter_append_basic(addr iter, TypeUInt32, addr rev)
    appendLayout(addr iter)
    send(conn, reply)
    return DBUS_HANDLER_RESULT_HANDLED

  if dbus_message_is_method_call(msg, MenuIface, "AboutToShow") != 0:
    let reply = dbus_message_new_method_return(msg)
    var iter: DBusMessageIter
    dbus_message_iter_init_append(reply, addr iter)
    # The layout has not changed since it was last fetched. Answering otherwise
    # makes some panels re-fetch the whole menu on every open.
    var needUpdate = cint(0)
    discard dbus_message_iter_append_basic(addr iter, TypeBoolean, addr needUpdate)
    send(conn, reply)
    return DBUS_HANDLER_RESULT_HANDLED

  if dbus_message_is_method_call(msg, MenuIface, "Event") != 0:
    var iter: DBusMessageIter
    if dbus_message_iter_init(msg, addr iter) != 0:
      let id = readInt32(addr iter)
      var eventId = ""
      if dbus_message_iter_next(addr iter) != 0:
        eventId = readString(addr iter)
      if eventId == "clicked" and not theTray.onAction.isNil:
        for item in theTray.items:
          if item.id == id and item.kind == tiAction:
            # On the GTK main loop, because the pump is driven from a GTK
            # timeout — so this may touch widget state directly.
            theTray.onAction(item.action)
            break
    send(conn, dbus_message_new_method_return(msg))
    return DBUS_HANDLER_RESULT_HANDLED

  # Action purpose: the two property methods have different return signatures —
  # one a single variant, the other a dictionary — so answering both the same way
  # is a mismatch the caller discards. The panel then never learns the menu's
  # version and may treat the object as not a menu at all.
  if dbus_message_is_method_call(msg, PropIface, "Get") != 0:
    let reply = dbus_message_new_method_return(msg)
    var iter: DBusMessageIter
    dbus_message_iter_init_append(reply, addr iter)
    appendVariantUint32(addr iter, DbusMenuVersion)
    send(conn, reply)
    return DBUS_HANDLER_RESULT_HANDLED

  if dbus_message_is_method_call(msg, PropIface, "GetAll") != 0:
    let reply = dbus_message_new_method_return(msg)
    var iter, dict, entry: DBusMessageIter
    dbus_message_iter_init_append(reply, addr iter)
    discard dbus_message_iter_open_container(addr iter, TypeArray, "{sv}", addr dict)
    discard dbus_message_iter_open_container(addr dict, TypeDictEntry, nil, addr entry)
    appendString(addr entry, "Version")
    appendVariantUint32(addr entry, DbusMenuVersion)
    discard dbus_message_iter_close_container(addr dict, addr entry)
    discard dbus_message_iter_close_container(addr iter, addr dict)
    send(conn, reply)
    return DBUS_HANDLER_RESULT_HANDLED

  DBUS_HANDLER_RESULT_NOT_YET_HANDLED

var itemVTable = DBusObjectPathVTable(message_function: cast[pointer](itemHandler))
var menuVTable = DBusObjectPathVTable(message_function: cast[pointer](menuHandler))

## Function purpose: answers false rather than raising when no watcher is
## running. A desktop without one is a supported environment — the window is the
## application and the tray is an addition — so this degrades to no icon and
## never to a failed start-up.
proc start*(title, iconName, tooltip: string, items: seq[TrayItem],
            onAction: TrayCallback): bool =
  var err: DBusError
  dbus_error_init(addr err)

  let conn = dbus_bus_get(DBUS_BUS_SESSION, addr err)
  if dbus_error_is_set(addr err) != 0 or conn.isNil:
    if dbus_error_is_set(addr err) != 0: dbus_error_free(addr err)
    return false
  dbus_connection_set_exit_on_disconnect(conn, 0)

  theTray = Tray(conn: conn, items: items, status: tsActive, title: title,
                 iconName: iconName, tooltip: tooltip, onAction: onAction,
                 revision: 1)

  # The bus name's shape is fixed by the specification, and carrying the pid is
  # what makes it unique per process.
  let busName = "org.kde.StatusNotifierItem-" & $getCurrentProcessId() & "-1"
  discard dbus_bus_request_name(conn, busName.cstring, NameFlagReplaceExisting, addr err)
  if dbus_error_is_set(addr err) != 0:
    dbus_error_free(addr err)
    return false

  if dbus_connection_register_object_path(conn, ItemPath, addr itemVTable, nil) == 0:
    return false
  if dbus_connection_register_object_path(conn, MenuPath, addr menuVTable, nil) == 0:
    return false

  let reg = dbus_message_new_method_call(WatcherName, WatcherPath,
                                         WatcherName, "RegisterStatusNotifierItem")
  if reg.isNil:
    return false
  var iter: DBusMessageIter
  dbus_message_iter_init_append(reg, addr iter)
  appendString(addr iter, busName)
  let reply = dbus_connection_send_with_reply_and_block(conn, reg, 2000, addr err)
  dbus_message_unref(reg)
  if dbus_error_is_set(addr err) != 0:
    # No watcher on this desktop. Not an error: window only, no tray.
    dbus_error_free(addr err)
    return false
  if not reply.isNil:
    dbus_message_unref(reply)

  theTray.registered = true
  true

## Function purpose: called from a GTK timeout, so the dispatch timeout must be
## zero — anything else stalls the interface for that long on every tick.
proc pump*() =
  if theTray.isNil or theTray.conn.isNil:
    return
  discard dbus_connection_read_write_dispatch(theTray.conn, 0)

## Function purpose: the signal is what makes a panel re-read the property.
## Setting the status without emitting leaves the icon showing whatever it read
## when it first appeared.
proc setStatus*(s: TrayStatus) =
  if theTray.isNil or not theTray.registered or theTray.status == s:
    return
  theTray.status = s
  let sig = dbus_message_new_signal(ItemPath, ItemIface, "NewStatus")
  if sig.isNil: return
  var iter: DBusMessageIter
  dbus_message_iter_init_append(sig, addr iter)
  appendString(addr iter, $s)
  send(theTray.conn, sig)

## Function purpose: the whole menu is replaced rather than one item patched,
## because dbusmenu revisions the layout as a unit.
proc setItems*(items: seq[TrayItem]) =
  if theTray.isNil: return
  theTray.items = items
  theTray.revision += 1
  if not theTray.registered: return
  let sig = dbus_message_new_signal(MenuPath, MenuIface, "LayoutUpdated")
  if sig.isNil: return
  var iter: DBusMessageIter
  dbus_message_iter_init_append(sig, addr iter)
  var rev = cuint(theTray.revision)
  discard dbus_message_iter_append_basic(addr iter, TypeUInt32, addr rev)
  appendInt32(addr iter, 0)
  send(theTray.conn, sig)

