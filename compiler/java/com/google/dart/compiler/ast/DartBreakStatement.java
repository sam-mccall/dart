// Copyright (c) 2011, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

package com.google.dart.compiler.ast;

/**
 * Represents a Dart 'break' statement.
 */
public class DartBreakStatement extends DartGotoStatement {

  public DartBreakStatement(DartIdentifier label) {
    super(label);
  }

  @Override
  public boolean isAbruptCompletingStatement() {
    return true;
  }

  @Override
  public <R> R accept(ASTVisitor<R> visitor) {
    return visitor.visitBreakStatement(this);
  }
}
