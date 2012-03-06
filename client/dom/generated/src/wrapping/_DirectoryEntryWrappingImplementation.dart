// Copyright (c) 2011, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// WARNING: Do not edit - generated code.

class _DirectoryEntryWrappingImplementation extends _EntryWrappingImplementation implements DirectoryEntry {
  _DirectoryEntryWrappingImplementation() : super() {}

  static create__DirectoryEntryWrappingImplementation() native {
    return new _DirectoryEntryWrappingImplementation();
  }

  DirectoryReader createReader() {
    return _createReader(this);
  }
  static DirectoryReader _createReader(receiver) native;

  void getDirectory(String path, [Object flags = null, EntryCallback successCallback = null, ErrorCallback errorCallback = null]) {
    if (flags === null) {
      if (successCallback === null) {
        if (errorCallback === null) {
          _getDirectory(this, path);
          return;
        }
      }
    } else {
      _getDirectory_2(this, path, flags, successCallback, errorCallback);
      return;
    }
    throw "Incorrect number or type of arguments";
  }
  static void _getDirectory(receiver, path) native;
  static void _getDirectory_2(receiver, path, flags, successCallback, errorCallback) native;

  void getFile(String path, [Object flags = null, EntryCallback successCallback = null, ErrorCallback errorCallback = null]) {
    if (flags === null) {
      if (successCallback === null) {
        if (errorCallback === null) {
          _getFile(this, path);
          return;
        }
      }
    } else {
      _getFile_2(this, path, flags, successCallback, errorCallback);
      return;
    }
    throw "Incorrect number or type of arguments";
  }
  static void _getFile(receiver, path) native;
  static void _getFile_2(receiver, path, flags, successCallback, errorCallback) native;

  void removeRecursively(VoidCallback successCallback, [ErrorCallback errorCallback = null]) {
    _removeRecursively(this, successCallback, errorCallback);
    return;
  }
  static void _removeRecursively(receiver, successCallback, errorCallback) native;

  String get typeName() { return "DirectoryEntry"; }
}
