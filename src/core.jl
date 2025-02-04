"""
    JavaRef is abstract parent for JavaLocalRef, JavaGlobalRef, and JavaNullRef in the JavaCall Module

    It is distinct from its parent type, JavaCall.JNI.AbstractJavaRef, since its use is defined in 
    JavaCall itself rather than the JNI submodule.
"""
abstract type JavaRef <: JNI.AbstractJavaRef end

"""
    JavaLocalRef is a JavaRef that is meant to be used with local variables in a function call.
    After the function call these references may be freed and garbage collected. See note about
    JNI memory management below.

    This is the default reference type returned from the JNI.

    Use this with JNI.PushLocalFrame / JNI.PopLocalFrame for memory management.
    Also see JNI.EnsureLocalCapacity.

    The internal pointer should be deleted using JNI.DeleteLocalRef
"""
struct JavaLocalRef <: JavaRef
    ptr::Ptr{Nothing}
end

"""
    JavaGlobalRef is a JavaRef that is meant to be used with global variables that live beyond 
    a single function call.
"""
struct JavaGlobalRef <: JavaRef
    ptr::Ptr{Nothing}
end

"""
    JavaNullRef is a JavaRef that serves as a placeholder to mark where references have already been deleted.

    See J_NULL
"""
struct JavaNullRef <: JavaRef
    ptr::Ptr{Nothing}
    JavaNullRef() = new(C_NULL)
end

""" Constant JavaNullRef """
const J_NULL = JavaNullRef()

Ptr(ref::JavaRef) = ref.ptr
Ptr{Nothing}(ref::JavaRef) = ref.ptr

JavaLocalRef(ref::JavaRef) = JavaLocalRef(JNI.NewLocalRef(Ptr(ref)))
JavaGlobalRef(ref::JavaRef) = JavaGlobalRef(JNI.NewGlobalRef(Ptr(ref)))

# _deleteref does local/global reference deletion without null or state checking
_deleteref(ref::JavaLocalRef ) = JNI.DeleteLocalRef( Ptr(ref))
_deleteref(ref::JavaGlobalRef) = JNI.DeleteGlobalRef(Ptr(ref))
_deleteref(ref::JavaNullRef) = nothing

"""
    deleteref deletes a JavaRef using either JNI.DeleteLocalRef or JNI.DeleteGlobalRef
"""
function deleteref(x::JavaRef)
    if x.ptr == C_NULL; return; end
    if !JNI.is_env_loaded(); return; end;
    _deleteref(x)
    return
end

"""
    jlocalframe(f, [returntype]; [capacity = 16])
    
    Manages java local references by using JNI's PushLocalFrame and PopLocalFrame.
    Only the local reference returned by f will be valid. Other local references
    will be freed and available for garbage collection.

    Specifying a `returntype` will allow for type stability. If `returntype` is
    specified and is not `Nothing` or `Any`, it will also be passed to the function.

    Capacity specifies the minimum number of local references that can be
    created. See the [JNI documentation](
    https://docs.oracle.com/en/java/javase/15/docs/specs/jni/functions.html#pushlocalframe
    )
    for further information.

    # Example
    ```
    julia> jlocalframe() do
               a = JObject() # Local reference created, will be GCed
               println(a)
               b = JObject() # Local reference returned
               println(b)
               b
           end

    julia> jlocalframe(JObject) do T # Specify returntype for type stability
               a = T()
               println(a)
               b = T()
               println(b)
               b
           end
    
    julia> jlocalframe(Nothing) do # Specify Nothing if you do want to return anything
               a = JObject()
               println(a)
           end
    ```
"""
function jlocalframe(f::Function, returntype::Type = Any; capacity = 16)
    JNI.PushLocalFrame(jint(capacity))
    result_ref = C_NULL
    return_ref = JavaLocalRef(result_ref)
    result = nothing
    try
        if returntype == Any
            result = f()
        else
            result = f(returntype)
        end
        if isa(result, JavaObject)
            result = Ptr{Nothing}(result)
        end
        if isa(result, Ptr{Nothing}) &&
           JNI.GetObjectRefType(result) == JNI.JNILocalRefType
            result_ref = result
        end
    catch err
        rethrow(err)
    finally
        return_ref = JavaLocalRef( JNI.PopLocalFrame(result_ref) )
    end

    # Return
    if returntype == Any # Not Type Stable
        if !isnull(return_ref.ptr)
            return narrow( JObject(return_ref) )
        else
            return result
        end
    elseif returntype <: JavaObject
        return returntype(return_ref)
    else
        return result::returntype
    end
end

# Closer to https://github.com/ahnlabb/BioformatsLoader.jl/commit/4d4e2d5decd87c8bfd2bfca2fdfbc4214b120977
function jlocalframe(f::Function, returntype::Type{Nothing}; capacity = 16)
    JNI.PushLocalFrame(jint(capacity))
    try
        f()
    catch err
        rethrow(err)
    finally
        JNI.PopLocalFrame(C_NULL)
    end
    return nothing
end

"""
    JavaMetaClass represents meta information about a Java class

    These are usually cached in _jmc_cache and are meant to live
    as long as the cache is valid.
"""
struct JavaMetaClass{T} <: JNI.AbstractJavaRef
    ref::JavaRef
end

#The metaclass, sort of equivalent to a the
JavaMetaClass(T, ref::JavaRef) = JavaMetaClass{T}(ref)
JavaMetaClass(T, ptr::Ptr{Nothing}) = JavaMetaClass{T}(JavaGlobalRef(ptr))

ref(mc::JavaMetaClass{T}) where T = mc.ref
Ptr(mc::JavaMetaClass{T}) where T = Ptr(mc.ref)
Ptr{Nothing}(mc::JavaMetaClass{T}) where T = Ptr(mc.ref)

"""
    JavaObject{T} is the main JavaCall type representing either an instance
    or a static class

    T is usually a symbol referring a Java class name
"""
mutable struct JavaObject{T} <: JNI.AbstractJavaRef
    ref::JavaRef

    #This below is ugly. Once we stop supporting 0.5, this can be replaced by
    # function JavaObject{T}(ptr) where T
    function JavaObject{T}(ref) where T
        j = new{T}(ref)
        finalizer(deleteref, j)
        return j
    end

    #replace with: JavaObject{T}(argtypes::Tuple, args...) where T
    JavaObject{T}(argtypes::Tuple, args...) where {T} = jnew(T, argtypes, args...)
end

# JavaObject Construction
JavaObject(ptr) = JObject(ptr)
JavaObject(T, ptr) = JavaObject{T}(ptr)
JavaObject{T}() where {T} = JavaObject{T}((),)
JavaObject{T}(ptr::Ptr{Nothing}) where {T} = JavaObject{T}(JavaLocalRef(ptr))

# JavaObject Reference Management
ref(x::JavaObject{T}) where T = x.ref
copyref(x::JavaObject{T}) where T = JavaObject{T}(JavaLocalRef(x.ref))
deleteref(x::JavaObject{T}) where T = ( deleteref(x.ref); x.ref = J_NULL )

# Obtain the underlying pointer for a JavaObject
Ptr(x::JavaObject{T}) where T = Ptr(x.ref)
Ptr{Nothing}(x::JavaObject{T}) where T = Ptr(x.ref)

"""
   jglobal(x::JavaObject) creates a new JavaGlobalRef and deletes the prior JavaRef
"""
function jglobal(x::JavaObject)
    gref = JavaGlobalRef(JNI.NewGlobalRef(Ptr(x)))
    deleteref(x.ref)
    x.ref = gref
end

"""
```
isnull(obj::JavaObject)
```
Checks if the passed JavaObject is null or not

### Args
* obj: The object of type JavaObject

### Returns
true if the passed object is null else false
"""
isnull(obj::JavaObject) = Ptr(obj) == C_NULL
isnull(obj::Ptr{Nothing}) = obj == C_NULL

"""
```
isnull(obj::JavaMetaClass)
```
Checks if the passed JavaMetaClass is null or not

### Args
* obj: The object of type JavaMetaClass

### Returns
true if the passed object is null else false
"""
isnull(obj::JavaMetaClass) = Ptr(obj) == C_NULL

macro checknull(expr, msg="")
    if expr isa Expr && expr.head == :call
        jnifun = "$(expr.args[1])"
        quote
            local ptr = $(esc(expr))
            if isnull(ptr) && geterror() === nothing
                throw(JavaCallError("JavaCall."*$jnifun*": "*$(esc(msg))))
            end
            ptr
        end
    else
        quote
            local ptr = $(esc(expr))
            if isnull(ptr) && geterror() === nothing
                throw(JavaCallError($(esc(msg))))
            end
            ptr
        end
    end
end

function checknull(ptr, msg="Unexpected null pointer from Java Native Interface", jnifun=nothing)
    if isnull(ptr) && geterror() === nothing
        if jnifun === nothing
            throw(JavaCallError(msg))
        else
            throw(JavaCallError("JavaCall.JNI.$jnifun: $msg"))
        end
    end
    ptr
end

const JClass = JavaObject{Symbol("java.lang.Class")}
const JObject = JavaObject{Symbol("java.lang.Object")}
const JMethod = JavaObject{Symbol("java.lang.reflect.Method")}
const JConstructor = JavaObject{Symbol("java.lang.reflect.Constructor")}
const JField = JavaObject{Symbol("java.lang.reflect.Field")}
const JThread = JavaObject{Symbol("java.lang.Thread")}
const JClassLoader = JavaObject{Symbol("java.lang.ClassLoader")}
const JString = JavaObject{Symbol("java.lang.String")}

#JavaObject(ptr::Ptr{Nothing}) = ptr == C_NULL ? JavaObject(ptr) : JavaObject{Symbol(getclassname(getclass(ptr)))}(ptr)

function JString(str::AbstractString)
    jstring = @checknull JNI.NewStringUTF(String(str))
    return JString(jstring)
end

# jvalue(v::Integer) = int64(v) << (64-8*sizeof(v))
jvalue(v::Integer)::JNI.jvalue = JNI.jvalue(v)
jvalue(v::Float32) = jvalue(reinterpret(Int32, v))
jvalue(v::Float64) = jvalue(reinterpret(Int64, v))
jvalue(v::Ptr) = jvalue(Int(v))
jvalue(v::JavaObject) = jvalue(Ptr(v))


function _jimport(juliaclass)
    for str ∈ [" ", "(", ")"]
        juliaclass = replace(juliaclass, str=>"")
    end
    :(JavaObject{Symbol($juliaclass)})
end

macro jimport(class::Expr)
    juliaclass = sprint(Base.show_unquoted, class)
    _jimport(juliaclass)
end
macro jimport(class::Symbol)
    juliaclass = string(class)
    _jimport(juliaclass)
end
macro jimport(class::AbstractString)
    _jimport(class)
end

const primitive_names_to_types = Dict(
    :boolean => jboolean,
    :byte    => jbyte,
    :char    => jchar,
    :short   => jshort,
    :int     => jint,
    :long    => jlong,
    :float   => jfloat,
    :double  => jdouble,
    :void    => jvoid
)
jimport(juliaclass::Symbol) = juliaclass == :void ? Nothing :
    haskey(primitive_names_to_types, juliaclass) ? jimport(juliaclass, Val(true), Val(false)) : JavaObject{juliaclass}
jimport(juliaclass::Symbol, isprimitive::Val{false}, isarray::Val{false}) = jimport(juliaclass)
jimport(juliaclass::Symbol, isprimitive::Val{true},  isarray::Val{false}) = primitive_names_to_types[juliaclass]

jimport(juliaclass::String, args...) = isarray(juliaclass) ? Vector{ jimport(Symbol(juliaclass[1:end-2])) } : jimport(Symbol(juliaclass), args...)

function jimport(juliaclass::JClass)
    jimport(juliaclass, Val(isprimitive(juliaclass)), Val(isarray(juliaclass)))
end
function jimport(juliaclass::JClass, isprimitive, isarray::Val{true})
    elementType = jimport( jcall(juliaclass, "getComponentType", JClass) )
    Vector{elementType}
end
jimport(juliaclass::JClass, isprimitive, isarray::Val{false}) = jimport(getname(juliaclass), isprimitive, isarray)

isprimitive(juliaclass::JClass) = jcall(juliaclass, "isPrimitive", jboolean, ()) == 0x01
isarray(juliaclass::JClass) = jcall(juliaclass, "isArray", jboolean, ()) == 0x01
isarray(juliaclass::String) = endswith(juliaclass, "[]")

function jnew(T::Symbol, argtypes::Tuple = () , args...)
    assertroottask_or_goodenv() && assertloaded()
    jmethodId = get_method_id(JNI.GetMethodID, T, "<init>", Nothing, argtypes)
    return _jcall(metaclass(T), jmethodId, JavaObject{T}, argtypes, args...; callmethod=JNI.NewObjectA)
end

_jcallable(typ::Type{JavaObject{T}}) where T = metaclass(T)
function _jcallable(obj::JavaObject)
    isnull(obj) && throw(JavaCallError("Attempt to call method on Java NULL"))
    obj
end

function jcall(ref, method::AbstractString, rettype::Type, argtypes::Tuple = (), args...)
    assertroottask_or_goodenv() && assertloaded()
    jmethodId = get_method_id(ref, method, rettype, argtypes)
    _jcall(_jcallable(ref), jmethodId, rettype, argtypes, args...)
end

function jcall(ref, method::JMethod, args...)
    assertroottask_or_goodenv() && assertloaded()
    jmethodId = get_method_id(method)
    rettype = jimport(getreturntype(method))
    argtypes = Tuple(jimport.(getparametertypes(method)))
    _jcall(_jcallable(ref), jmethodId, rettype, argtypes, args...)
end

function get_method_id(jnifun::Function, obj, method::AbstractString, rettype::Type, argtypes::Tuple)
    sig = method_signature(rettype, argtypes...)
    ptr = Ptr(metaclass(obj))
    @checknull jnifun(ptr, String(method), sig) "Problem getting method id for $obj.$method with signature $sig"
end

function get_method_id(typ::Type{JavaObject{T}}, method::AbstractString, rettype::Type, argtypes::Tuple) where T
    get_method_id(JNI.GetStaticMethodID, T, method, rettype, argtypes)
end

function get_method_id(obj::JavaObject, method::AbstractString, rettype::Type, argtypes::Tuple)
    get_method_id(JNI.GetMethodID, obj, method, rettype, argtypes)
end

get_method_id(method::JMethod) = @checknull JNI.FromReflectedMethod(method)

# JMethod invoke
(m::JMethod)(obj, args...) = jcall(obj, m, args...)


"""
    jfield(ref, field, [fieldType])

Get a pointer to a field of of a Java class or object.
* `ref` could be a JavaObject{T} type or a JavaObject
* `field` can be an AbstractString or JField
* `fieldType` is a Type
"""
function jfield(ref, field, fieldType)
    assertroottask_or_goodenv() && assertloaded()
    jfieldID = get_field_id(ref, field, fieldType)
    _jfield(_jcallable(ref), jfieldID, fieldType)
end

function jfield(ref, field)
    assertroottask_or_goodenv() && assertloaded()
    fieldType = jimport(gettype(field))
    jfieldID = get_field_id(ref, field, fieldType)
    _jfield(_jcallable(ref), jfieldID, fieldType)
end

function jfield(ref, field::AbstractString)
    assertroottask_or_goodenv() && assertloaded()
    field = listfields(ref, field)[]
    fieldType = jimport(gettype(field))
    jfieldID = get_field_id(ref, field)
    _jfield(_jcallable(ref), jfieldID, fieldType)
end

function get_field_id(typ::Type{JavaObject{T}}, field::AbstractString, fieldType::Type) where T
    @checknull JNI.GetStaticFieldID(Ptr(metaclass(T)), String(field), signature(fieldType))
end

function get_field_id(obj::Type{JavaObject{T}}, field::JField) where T
    fieldType = jimport(gettype(field))
    @checknull JNI.FromReflectedField(field)
end

function get_field_id(obj::JavaObject, field::AbstractString, fieldType::Type)
    @checknull JNI.GetFieldID(Ptr(metaclass(obj)), String(field), signature(fieldType))
end

function get_field_id(obj::JavaObject, field::JField, fieldType::Type)
    @checknull JNI.FromReflectedField(field)
end

# JField invoke
(f::JField)(obj) = jfield(obj, f)

for (x, name) in [(:(<:Any),  :Object),
                  (:jboolean, :Boolean),
                  (:jchar,    :Char   ),
                  (:jbyte,    :Byte   ),
                  (:jshort,   :Short  ),
                  (:jint,     :Int    ),
                  (:jlong,    :Long   ),
                  (:jfloat,   :Float  ),
                  (:jdouble,  :Double ),
                  (:jvoid,    :Void   )]
    for (t, callprefix, getprefix) in [
        (:JavaObject,    :Call, :Get ),
        (:JavaMetaClass, :CallStatic, :GetStatic )
    ]
        callmethod = :(JNI.$(Symbol(callprefix, name, :MethodA)))
        fieldmethod = :(JNI.$(Symbol(getprefix, name, :Field)))
        m = quote
            function _jfield(obj::T, jfieldID::Ptr{Nothing}, fieldType::Type{$x}) where T <: $t
                result = $fieldmethod(Ptr(obj), jfieldID)
                geterror()
                return convert_result(fieldType, result)
            end
            function _jcall(obj::T, jmethodId::Ptr{Nothing}, rettype::Type{$x},
                            argtypes::Tuple, args...; callmethod=$callmethod) where T <: $t
                savedArgs, convertedArgs = convert_args(argtypes, args...)
                GC.@preserve savedArgs begin
                    result = callmethod(Ptr(obj), jmethodId, Array{JNI.jvalue}(jvalue.(convertedArgs)))
                end
                cleanup_arg.(convertedArgs)
                geterror()
                return convert_result(rettype, result)
            end
        end
        eval(m)
    end
end

cleanup_arg(arg) = nothing
cleanup_arg(arg::JavaObject) = deleteref(arg)

global const _jmc_cache = [ Dict{Symbol, JavaMetaClass}() ]

function _metaclass(class::Symbol)
    jclass=javaclassname(class)
    jclassptr = @checknull JNI.FindClass(jclass)
    return JavaMetaClass(class, jclassptr)
end

function metaclass(class::Symbol)
    return _metaclass(class)
    if !haskey(_jmc_cache[ Threads.threadid() ], class)
        _jmc_cache[ Threads.threadid() ][class] = _metaclass(class)
    end
    return _jmc_cache[ Threads.threadid() ][class]
end

metaclass(::Type{JavaObject{T}}) where {T} = metaclass(T)
metaclass(::JavaObject{T}) where {T} = metaclass(T)
metaclass(::Type{T}) where T <: AbstractVector = metaclass( Symbol( JavaCall.signature(T) ) )

javaclassname(class::Symbol) = replace(string(class), "."=>"/")
javaclassname(class::AbstractString) = replace(class, "."=>"/")
javaclassname(::Type{T}) where T <: AbstractVector = JavaCall.signature(T)

function _notnull_assert(ptr)
    isnull(ptr) && throw(JavaCallError("Java Exception thrown, but no details could be retrieved from the JVM"))
end

function get_exception_string(jthrow)
    jthrowable = JNI.FindClass("java/lang/Throwable")
    _notnull_assert(jthrowable)

    tostring_method = JNI.GetMethodID(jthrowable, "toString", "()Ljava/lang/String;")
    _notnull_assert(tostring_method)

    res = JNI.CallObjectMethodA(jthrow, tostring_method, Int[])
    _notnull_assert(res)

    return unsafe_string(JString(res))
end

function geterror()
    isexception = JNI.ExceptionCheck()

    if isexception == JNI_TRUE
        jthrow = JNI.ExceptionOccurred()
        _notnull_assert(jthrow)
        try
            JNI.ExceptionDescribe() #Print java stackstrace to stdout

            msg = get_exception_string(jthrow)
            throw(JavaCallError(string("Error calling Java: ", msg)))
        finally
            JNI.ExceptionClear()
            JNI.DeleteLocalRef(jthrow)
        end
    end
end

#get the JNI signature string for a method, given its
#return type and argument types
function method_signature(rettype, argtypes...)
    s=IOBuffer()
    write(s, "(")
    for arg in argtypes
        write(s, signature(arg))
    end
    write(s, ")")
    write(s, signature(rettype))
    return String(take!(s))
end

#get the JNI signature string for a given type
signature(::Type{jboolean}) = "Z"
signature(::Type{jbyte}) = "B"
signature(::Type{jchar}) = "C"
signature(::Type{jshort}) = "S"
signature(::Type{jint}) = "I"
signature(::Type{jlong}) = "J"
signature(::Type{jfloat}) = "F"
signature(::Type{jdouble}) = "D"
signature(::Type{jvoid}) = "V"
signature(::Type{Array{T,N}}) where {T,N} = string("[" ^ N, signature(T))
signature(arg::Type{JavaObject{T}}) where {T} = string("L", javaclassname(T), ";")
signature(arg::Type{JavaObject{T}}) where {T <: AbstractVector} = JavaCall.javaclassname(T)

