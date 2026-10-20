import Foundation

/**
 * Applies the ops a topic's delta carries to a value, as the core's own UI client does (and `Delta.kt` on Android):
 * `set`, `append`, `extend` (a string's added end) and `remove` at a path of object keys and array indexes, and the
 * keyed ones that change one item of a list found by its key (`put`, `patch`, `drop`, `move`). An op whose path does
 * not fit the value is skipped.
 *
 * Nothing of the value is changed: the result shares every object and array the ops did not reach, and has new ones
 * along each path they did. A reader can so tell what changed by identity, and keep what it read of the rest.
 */
enum Delta {
    static func apply(_ value: Any?, _ ops: NSArray) -> Any? {
        var root = value
        for case let op as NSDictionary in ops {
            guard let path = op["path"] as? NSArray else { continue }
            root = applyPath(root, path, 0, op)
        }
        return root
    }

    /// `holder` with `op` applied at the rest of `path` from `at`; `holder` itself when the op does not fit.
    private static func applyPath(_ holder: Any?, _ path: NSArray, _ at: Int, _ op: NSDictionary) -> Any? {
        if at == path.count { return applyAt(holder, op) }
        let key = path[at]
        let last = at == path.count - 1
        if let object = holder as? NSDictionary, let key = key as? String {
            if last && op["remove"] != nil {
                guard object[key] != nil else { return holder }
                let copy = object.mutableCopy() as! NSMutableDictionary
                copy.removeObject(forKey: key)
                return copy
            }
            // A missing last key is made by a `set`; anything else needs what is there.
            if object[key] == nil && !(last && op["set"] != nil) { return holder }
            let old = object[key]
            let next = applyPath(old, path, at + 1, op)
            if same(next, old) { return holder }
            let copy = object.mutableCopy() as! NSMutableDictionary
            copy[key] = next ?? NSNull()
            return copy
        }
        if let array = holder as? NSArray, let index = (key as? NSNumber).flatMap(integer), index >= 0, index < array.count,
           !(last && op["remove"] != nil) {
            let old = array[index]
            let next = applyPath(old, path, at + 1, op)
            if same(next, old) { return holder }
            let copy = array.mutableCopy() as! NSMutableArray
            copy[index] = next ?? NSNull()
            return copy
        }
        return holder
    }

    /// `target` after an op that changes the value at its path itself.
    private static func applyAt(_ target: Any?, _ op: NSDictionary) -> Any? {
        if let value = op["set"] { return value }
        if let items = op["append"] {
            guard let list = target as? NSArray, let items = items as? NSArray else { return target }
            return list.addingObjects(from: items as! [Any]) as NSArray
        }
        if let tail = op["extend"] {
            guard let text = target as? String, let tail = tail as? String else { return target }
            return (text + tail) as NSString
        }
        if op["key"] != nil {
            guard let list = target as? NSArray else { return target }
            return keyed(list, op)
        }
        return target
    }

    private static func same(_ left: Any?, _ right: Any?) -> Bool {
        switch (left, right) {
        case (nil, nil): return true
        case let (l?, r?): return (l as AnyObject) === (r as AnyObject)
        default: return false
        }
    }

    private static func integer(_ number: NSNumber) -> Int? {
        let value = number.doubleValue
        return value == value.rounded() ? Int(value) : nil
    }

    /// An item's key as text, to compare: the one field's value, or the fields' values in order.
    private static func keyText(_ item: Any?, _ fields: [String]) -> String {
        func field(_ name: String) -> Any { (item as? NSDictionary)?[name] ?? NSNull() }
        if fields.count == 1 { return text(field(fields[0])) }
        return text(fields.map(field) as NSArray)
    }

    private static func text(_ key: Any?) -> String {
        switch key {
        case nil, is NSNull: return "null"
        case let string as String:
            let data = (try? JSONSerialization.data(withJSONObject: string, options: [.fragmentsAllowed])) ?? Data()
            return String(decoding: data, as: UTF8.self)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
            // 3 and 3.0 are the same key however the JSON reader typed them.
            let value = number.doubleValue
            return value == value.rounded() && abs(value) < 9.0e15 ? String(Int64(value)) : String(value)
        case let list as NSArray:
            return "[" + list.map { text($0) }.joined(separator: ",") + "]"
        default:
            return "\(key!)"
        }
    }

    /// One keyed op on `list`: the list after it (a new one), or `list` itself when the op does not fit.
    private static func keyed(_ list: NSArray, _ op: NSDictionary) -> NSArray {
        guard let fields = op["key"] as? [String] else { return list }
        var items = list as! [Any]
        func find(_ key: Any?) -> Int? {
            let want = text(key)
            return items.firstIndex { keyText($0, fields) == want }
        }
        func place(_ item: Any, before: Any?) {
            if let before, !(before is NSNull), let at = find(before) { items.insert(item, at: at) } else { items.append(item) }
        }
        if let drop = op["drop"] {
            guard let at = find(drop) else { return list }
            items.remove(at: at)
        } else if let patch = op["patch"] {
            guard let at = find(patch) else { return list }
            items[at] = apply(items[at], op["ops"] as? NSArray ?? []) ?? NSNull()
        } else if let move = op["move"] {
            guard let at = find(move) else { return list }
            place(items.remove(at: at), before: op["before"])
        } else if let item = op["put"] {
            let want = keyText(item, fields)
            let at = items.firstIndex { keyText($0, fields) == want }
            if let at, op["before"] == nil {
                items[at] = item
            } else {
                if let at { items.remove(at: at) }
                place(item, before: op["before"])
            }
        } else {
            return list
        }
        return items as NSArray
    }
}
