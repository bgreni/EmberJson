from emberjson import JSON, minify as minify_mojo, parse as parse_mojo
from python import PythonObject, Python
from python.bindings import PythonModuleBuilder
import math
from os import abort


@export
fn PyInit_emberjson_python() -> PythonObject:
    try:
        var m = PythonModuleBuilder("emberjson_python")
        m.def_function[parse]("parse")
        m.def_function[minify]("minify")
        m.add_type[JSON]("JSON")
        return m.finalize()
    except e:
        return abort[PythonObject](
            String("error creating Python Mojo module:", e)
        )


fn parse(obj: PythonObject) raises -> PythonObject:
    # return parse_mojo(s).to_python_object()
    return PythonObject(alloc=parse_mojo(String(obj)))


fn minify(obj: PythonObject) raises -> PythonObject:
    return minify_mojo(String(obj))
