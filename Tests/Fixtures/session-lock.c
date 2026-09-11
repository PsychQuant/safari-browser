#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>

/* 77 means the GUI session cannot support a meaningful Accessibility test. */
int main(void) {
    CFDictionaryRef session = CGSessionCopyCurrentDictionary();
    if (session == NULL) return 77;
    CFTypeRef value = CFDictionaryGetValue(session, CFSTR("CGSSessionScreenIsLocked"));
    int result = 0;
    if (value != NULL) {
        result = CFGetTypeID(value) == CFBooleanGetTypeID()
            ? (CFBooleanGetValue((CFBooleanRef)value) ? 77 : 0) : 1;
    }
    CFRelease(session);
    return result;
}
