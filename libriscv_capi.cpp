/* macOS #defines stdout as __stdoutp, which clashes with the
   'stdout' field in RISCVOptions. Undef it before including. */
#ifdef __APPLE__
#include <cstdio>
#pragma push_macro("stdout")
#undef stdout
#endif

#include "libriscv.cpp"

#ifdef __APPLE__
#pragma pop_macro("stdout")
#endif
