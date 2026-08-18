namespace eval tablecache {

proc sized_hex_literal {width raw_value} {
    if {![string is integer -strict $width] || $width < 1 || $width > 64} {
        error "generic width must be an integer in 1..64, got '$width'"
    }

    set text [string map {_ ""} [string trim $raw_value]]
    set declared_width ""
    if {[regexp {^([0-9]+)'[hH]([0-9a-fA-F]+)$} $text -> declared_width digits]} {
        if {$declared_width != $width} {
            error "generic literal '$raw_value' declares width $declared_width, expected $width"
        }
        set value [expr "0x$digits"]
    } elseif {[regexp {^0[xX]([0-9a-fA-F]+)$} $text -> digits]} {
        set value [expr "0x$digits"]
    } elseif {[regexp {^[0-9]+$} $text]} {
        set value 0
        foreach digit [split $text ""] {
            scan $digit %d digit_value
            set value [expr {$value * 10 + $digit_value}]
        }
    } else {
        error "generic value '$raw_value' is not an unsigned decimal or hexadecimal integer"
    }

    set max_value [expr {(1 << $width) - 1}]
    if {$value < 0 || $value > $max_value} {
        error "generic value '$raw_value' does not fit in $width bits"
    }
    return "${width}'h[format %X $value]"
}

}
