proc tc_print_matching_lines {path pattern {limit 0}} {
    set stream [open $path r]
    set emitted 0
    while {[gets $stream line] >= 0} {
        if {[regexp $pattern $line]} {
            puts $line
            incr emitted
            if {$limit > 0 && $emitted >= $limit} {
                break
            }
        }
    }
    close $stream
}

proc tc_count_matching_lines {path pattern} {
    set stream [open $path r]
    set count 0
    while {[gets $stream line] >= 0} {
        if {[regexp $pattern $line]} {
            incr count
        }
    }
    close $stream
    return $count
}
