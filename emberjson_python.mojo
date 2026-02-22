from emberjson import Value, minify as minify_mojo, parse as parse_mojo
from python import PythonObject, Python
from python.bindings import PythonModuleBuilder
import math
from os import abort


fn _try_to_int(key: PythonObject) -> Optional[Int]:
    try:
        return Int(py=key)
    except e:
        return None


fn _try_to_str(key: PythonObject) -> Optional[String]:
    try:
        return String(key)
    except e:
        return None


__extension Value:
    @staticmethod
    fn _get_self(
        py_self: PythonObject,
    ) -> UnsafePointer[Self, MutAnyOrigin]:
        try:
            return py_self.downcast_value_ptr[Self]()
        except e:
            abort(
                String(
                    (
                        "Python method receiver object did not have the"
                        " expected type:"
                    ),
                    e,
                )
            )

    @staticmethod
    fn _py_get(py_self: PythonObject, key: PythonObject) raises -> PythonObject:
        ref self = Self._get_self(py_self)[]

        if ind := _try_to_int(key):
            return PythonObject(alloc=self[ind[]].copy())
        if k := _try_to_str(key):
            var s = k[]
            if not s.startswith("/"):
                s = "/" + s
            return PythonObject(alloc=self.get(s).copy())

        raise Error("key is not an integer or string: ", key)

    @staticmethod
    fn _to_py(py_self: PythonObject) raises -> PythonObject:
        ref self = Self._get_self(py_self)[]
        return self.to_python_object()


@export
fn PyInit_emberjson_python() -> PythonObject:
    try:
        var m = PythonModuleBuilder("emberjson_python")
        m.def_function[parse]("parse")
        m.def_function[minify]("minify")
        _ = (
            m.add_type[Value]("Value")
            .def_method[Value._py_get]("get")
            .def_method[Value._to_py]("to_py")
        )
        return m.finalize()
    except e:
        abort(String("error creating Python Mojo module:", e))


fn parse(obj: PythonObject) raises -> PythonObject:
    return PythonObject(alloc=parse_mojo(String(obj)))


fn minify(obj: PythonObject) raises -> PythonObject:
    return minify_mojo(String(obj)).to_python_object()
