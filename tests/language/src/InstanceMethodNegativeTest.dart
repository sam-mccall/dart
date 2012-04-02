// Copyright (c) 2011, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// Dart test to check that we correctly flag the use of an
// instance method from a static method.


class Goofy {
  String instMethod() {
    return "woof";
  }
  static String bark() {
    return instMethod();  // Should get error here.
  }
}

class InstanceMethodNegativeTest {
  static testMain() {
    var s = Goofy.bark();
  }
}


main() {
  InstanceMethodNegativeTest.testMain();
}
