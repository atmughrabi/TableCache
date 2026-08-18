source [file join [file dirname [info script]] generic_literals.tcl]

proc expect_equal {actual expected} {
    if {$actual ne $expected} {
        error "expected '$expected', got '$actual'"
    }
}

proc expect_error {script pattern} {
    if {![catch {uplevel 1 $script} message]} {
        error "expected error matching '$pattern'"
    }
    if {![string match $pattern $message]} {
        error "error '$message' does not match '$pattern'"
    }
}

expect_equal [tablecache::sized_hex_literal 32 0xFFFFFFFF] "32'hFFFFFFFF"
expect_equal [tablecache::sized_hex_literal 33 0x1_FFFF_FFFF] "33'h1FFFFFFFF"
expect_equal [tablecache::sized_hex_literal 34 17179869183] "34'h3FFFFFFFF"
expect_equal [tablecache::sized_hex_literal 32 010] "32'hA"
expect_equal [tablecache::sized_hex_literal 64 0xFFFFFFFFFFFFFFFF] "64'hFFFFFFFFFFFFFFFF"
expect_equal [tablecache::sized_hex_literal 64 64'h8000_0000_0000_0000] "64'h8000000000000000"

expect_error {
    tablecache::sized_hex_literal 33 0x3FFFFFFFF
} "*does not fit in 33 bits"
expect_error {
    tablecache::sized_hex_literal 32 037777777777
} "*does not fit in 32 bits"
expect_error {
    tablecache::sized_hex_literal 64 32'hFFFFFFFF
} "*declares width 32, expected 64"
expect_error {
    tablecache::sized_hex_literal 64 nope
} "*not an unsigned decimal or hexadecimal integer"

puts "generic literal tests: PASS"
