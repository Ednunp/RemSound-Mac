import AppKit

enum PeerStatusCell {
    static func make(name:String,address:String,selected:Bool,status:String) -> NSTextField {
        let field=NSTextField(labelWithString:"")
        field.setAccessibilityRole(.staticText)
        field.setAccessibilityHelp("Peer connection, ping and estimated latency. Missing stages are identified; reported values are not acoustic measurements.")
        _=update(field,name:name,address:address,selected:selected,status:status)
        return field
    }
    @discardableResult
    static func update(_ field:NSTextField,name:String,address:String,selected:Bool,status:String) -> Bool {
        let text="\(name), \(address), \(selected ? "selected" : "not selected"), \(status)"
        guard field.stringValue != text || field.accessibilityLabel() != text else { return false }
        field.stringValue=text
        field.setAccessibilityLabel(text)
        return true
    }
}
