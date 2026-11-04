if {[catch {
import_device eagle_s20.db -package EG4S20BG256
cd {D:/software/TD_Tangdynasty/alogic_project/B_project/src/td_project}
open_project B_project.al -single_run
elaborate -top top
} message]} {
 puts stderr "PROJECT_OPEN_FAILED: $message"
 exit 1
}
puts "PROJECT_OPEN_AND_ELABORATE_PASS"
exit 0
