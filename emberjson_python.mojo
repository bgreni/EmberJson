from emberjson import parse as parse_mojo
from python import PythonObject, Python
from python.bindings import PythonModuleBuilder
import math
from os import abort


@export
fn PyInit_emberjson_python() -> PythonObject:
    try:
        var m = PythonModuleBuilder("emberjson_python")
        m.def_function[parse]("parse")
        return m.finalize()
    except e:
        return abort[PythonObject](String("error creating Python Mojo module:", e))


fn parse(obj: PythonObject) raises -> PythonObject:
    var s = String(obj)

    return parse_mojo(s).to_python_object()