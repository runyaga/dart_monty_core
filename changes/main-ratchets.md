### Internal

- The local gate is green again on `main`. `FakeMontySession` keeps its public
  API with its scripting methods and its lifecycle in two private classes, so
  it is back under the class method-count limit; the worker fixture reads its
  `writer` arguments with a pattern in place of an unchecked index. No
  behaviour changes.
