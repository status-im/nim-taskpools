# Nim-Taskpools
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import macros

template letsGoDeeper =
  var rTree = node.kind.newTree()
  for child in node:
    rTree.add inspect(child)
  return rTree

proc replaceSymsByIdents*(ast: NimNode): NimNode =
  proc inspect(node: NimNode): NimNode =
    case node.kind:
    of {nnkIdent, nnkSym}:
      return ident($node)
    of nnkEmpty:
      return node
    of nnkLiterals:
      return node
    of nnkHiddenStdConv:
      if node[1].kind == nnkIntLit:
        return node[1]
      else:
        expectKind(node[1], nnkSym)
        return ident($node[1])
    else:
      letsGoDeeper()
  result = inspect(ast)
