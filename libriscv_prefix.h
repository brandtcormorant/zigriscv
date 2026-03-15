/* Workaround: macOS defines stdout as a macro (__stdoutp).
   libriscv's C API uses 'stdout' as a struct field name,
   which clashes. Push/undef it before including libriscv.h. */
#pragma push_macro("stdout")
#undef stdout
#pragma pop_macro("stdout")
