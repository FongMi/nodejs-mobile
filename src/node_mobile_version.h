#ifndef SRC_NODE_MOBILE_VERSION_H_
#define SRC_NODE_MOBILE_VERSION_H_

#include "node_version.h"

#define NODE_MOBILE_MAJOR_VERSION 24
#define NODE_MOBILE_MINOR_VERSION 15
#define NODE_MOBILE_PATCH_VERSION 0

// Mobile rebuild revision of the same upstream Node version: the -X in the
// nodejs-mobile-<upstream>-<rev> tag (e.g. 24.15.0-0). Bumped by prepare-release.
#define NODE_MOBILE_REVISION 0

#define NODE_MOBILE_VERSION_IS_RELEASE NODE_VERSION_IS_RELEASE

# if NODE_MOBILE_VERSION_IS_RELEASE
#  define NODE_MOBILE_TAG ""
# else
#  define NODE_MOBILE_TAG "-pre"
# endif

#define NODE_MOBILE_VERSION_STRING \
  NODE_STRINGIFY(NODE_MOBILE_MAJOR_VERSION) "." \
  NODE_STRINGIFY(NODE_MOBILE_MINOR_VERSION) "." \
  NODE_STRINGIFY(NODE_MOBILE_PATCH_VERSION) "-" \
  NODE_STRINGIFY(NODE_MOBILE_REVISION)          \
  NODE_MOBILE_TAG

#endif  // SRC_NODE_MOBILE_VERSION_H_
