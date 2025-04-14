
type
  FooObj = object
    bar: int
  Foo = ref FooObj

var fff: FooObj

body.add $fff.bar


