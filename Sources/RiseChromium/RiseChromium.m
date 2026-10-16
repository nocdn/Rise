// Rise's engine interface (include/RiseChromium.h) on Rise's own Chromium fork, where it's built
// into Chrome's framework (chrome/browser/rise in the fork; see Engine/fork-plan.md). This module
// gives Swift the header; the classes come from the framework.
//
// It also hands the framework Rise's ad-blocking engine (Engine/adblock) as Rise starts. The
// engine stays in Rise's own code, with its own Rust, apart from the framework's.
#import <stdbool.h>

#if RISE_ADBLOCK
bool rise_adblock_load(void);
bool rise_adblock_blocks(const char *url, const char *source, const char *kind);
char *rise_adblock_hidden(const char *url, const char *classes, const char *ids);
void rise_adblock_free_string(char *value);
void RCAdBlockUseEngine(bool (*load)(void), bool (*blocks)(const char *, const char *, const char *),
                        char *(*hidden)(const char *, const char *, const char *), void (*free_string)(char *));

__attribute__((constructor)) static void RiseUseAdBlock(void) {
  RCAdBlockUseEngine(rise_adblock_load, rise_adblock_blocks, rise_adblock_hidden, rise_adblock_free_string);
}
#endif
