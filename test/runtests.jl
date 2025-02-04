using Test
using JavaCall

import Dates
using Base.GC: gc


macro testasync(x)
    :( @test (@sync @async eval($x)).result ) |> esc
end
macro syncasync(x)
    :( (@sync @async eval($x)).result ) |> esc
end

JAVACALL_FORCE_ASYNC_INIT = get(ENV,"JAVACALL_FORCE_ASYNC_INIT","") ∈ ("1","yes")
JAVACALL_FORCE_ASYNC_TEST = get(ENV,"JAVACALL_FORCE_ASYNC_TEST","") ∈ ("1","yes")

@testset "initialization" begin
    JavaCall.addClassPath("foo")
    JavaCall.addOpts("-Djava.class.path=bar")
    JavaCall.addOpts("-Xmx512M")
    if JavaCall.JULIA_COPY_STACKS || JAVACALL_FORCE_ASYNC_INIT
        @testasync JavaCall.init(["-Djava.class.path=$(@__DIR__)"])==nothing
    else
        @test JavaCall.init(["-Djava.class.path=$(@__DIR__)"])==nothing
    end
    @test match(r"foo[:;]+bar",JavaCall.getClassPath()) != nothing
    # JavaCall.init(["-verbose:gc","-Djava.class.path=$(@__DIR__)"])
    # JavaCall.init()
end

System = @jimport java.lang.System
System_out = jfield(System, "out", @jimport java.io.PrintStream )
@info "Java Version: ", jcall(System, "getProperty", JString, (JString,), "java.version")

@testset "JavaCall" begin

@testset "unsafe_strings_1" begin
    a=JString("how are you")
    @test Ptr(a) != C_NULL
    @test 11 == JavaCall.JNI.GetStringUTFLength(Ptr(a))
    b = JavaCall.JNI.GetStringUTFChars(Ptr(a),Ref{JavaCall.JNI.jboolean}())
    @test unsafe_string(b) == "how are you"
end

T = @jimport Test

@testset "parameter_passing_1" begin
    @test 10 == jcall(T, "testShort", jshort, (jshort,), 10)
    @test 10 == jcall(T, "testInt", jint, (jint,), 10)
    @test 10 == jcall(T, "testLong", jlong, (jlong,), 10)
    @test typemax(jint) == jcall(T, "testInt", jint, (jint,), typemax(jint))
    @test typemax(jlong) == jcall(T, "testLong", jlong, (jlong,), typemax(jlong))
    @test "Hello Java"==jcall(T, "testString", JString, (JString,), "Hello Java")
    @test Float64(10.02) == jcall(T, "testDouble", jdouble, (jdouble,), 10.02) #Comparing exact float representations hence ==
    @test Float32(10.02) == jcall(T, "testFloat", jfloat, (jfloat,), 10.02)
    @test floatmax(jdouble) == jcall(T, "testDouble", jdouble, (jdouble,), floatmax(jdouble))
    @test floatmax(jfloat) == jcall(T, "testFloat", jfloat, (jfloat,), floatmax(jfloat))
    c=JString(C_NULL)
    @test isnull(c)
    @test "" == jcall(T, "testString", JString, (JString,), c)
    a = rand(10^7)
    @test [jcall(T, "testDoubleArray", jdouble, (Array{jdouble,1},),a)
           for i in 1:10][1] ≈ sum(a)
    a = nothing
end

@testset "static_method_call_1" begin
    jlm = @jimport "java.lang.Math"
    @test 1.0 ≈ jcall(jlm, "sin", jdouble, (jdouble,), pi/2)
    @test 1.0 ≈ jcall(jlm, "min", jdouble, (jdouble,jdouble), 1,2)
    @test 1 == jcall(jlm, "abs", jint, (jint,), -1)
end

@testset "static_method_call_async_1" begin
    jlm = @jimport "java.lang.Math"
    if JAVACALL_FORCE_ASYNC_TEST || JavaCall.JULIA_COPY_STACKS || Sys.iswindows()
        @testasync 1.0 ≈ jcall(jlm, "sin", jdouble, (jdouble,), pi/2)
        @testasync 1.0 ≈ jcall(jlm, "min", jdouble, (jdouble,jdouble), 1,2)
        @testasync 1 == jcall(jlm, "abs", jint, (jint,), -1)
    end
end


@testset "instance_methods_1" begin
    jnu = @jimport java.net.URL
    gurl = jnu((JString,), "https://en.wikipedia.org")
    @test "en.wikipedia.org"==jcall(gurl, "getHost", JString,())
    jni = @jimport java.net.URI
    guri=jcall(gurl, "toURI", jni,())
    @test typeof(guri)==jni

    h=jcall(guri, "hashCode", jint,())
    @test typeof(h)==jint
end

@testset "method_styles_1" begin
    method_dict(x) = map(listmethods(x)) do m
        param_t = Tuple(JavaCall.jimport.(getparametertypes(m)))
        ret_t = JavaCall.jimport(getreturntype(m))
        (getname(m), ret_t, param_t) => m
    end |> Dict


    jmath = @jimport java.lang.Math 
    methods = method_dict(jmath)
    for (method_key, params) in [(("hypot", jdouble, (jdouble, jdouble)), (2.0, 3.0)),
                                 (("getExponent", jint, (jfloat,)), (1.0))
                                ]
        res = jcall(jmath, method_key..., params...)
        @test res == methods[method_key](jmath, params...)
        @test res == jcall(jmath, methods[method_key], params...)
    end

    jnu = @jimport java.net.URL
    gurl = jnu((JString,), "https://en.wikipedia.org")
    methods = method_dict(gurl)
    for (method_key, params) in [(("getProtocol", JString, ()), ()),
                                 (("getHost", JString, ()), ())
                                ]
        res = jcall(gurl, method_key..., params...)
        @test res == methods[method_key](gurl, params...)
        @test res == jcall(gurl, methods[method_key], params...)
    end
end

@testset "exceptions_1" begin
    j_u_arrays = @jimport java.util.Arrays
    j_math = @jimport java.lang.Math
    j_is = @jimport java.io.InputStream

@static if !Sys.isapple()

    # JavaCall.JavaCallError("Error calling Java: java.lang.ArithmeticException: / by zero")
    @info "Expecting: \"Error calling Java: java.lang.ArithmeticException: / by zero\""
    @test_throws JavaCall.JavaCallError jcall(j_math, "floorDiv", jint, (jint, jint), 1, 0)
    @test JavaCall.geterror() === nothing

    # JavaCall.JavaCallError("Error calling Java: java.lang.ArrayIndexOutOfBoundsException: Array index out of range: -1")
    @info "Expecting: \"Error calling Java: java.lang.ArrayIndexOutOfBoundsException: Array index out of range: -1\""
    @test_throws JavaCall.JavaCallError jcall(j_u_arrays, "sort", Nothing, (Array{jint,1}, jint, jint), [10,20], -1, -1)
    @test JavaCall.geterror() === nothing

    # JavaCall.JavaCallError("Error calling Java: java.lang.IllegalArgumentException: fromIndex(1) > toIndex(0)")
    @info "Expecting: \"Error calling Java: java.lang.IllegalArgumentException: fromIndex(1) > toIndex(0)\""
    @test_throws JavaCall.JavaCallError jcall(j_u_arrays, "sort", Nothing, (Array{jint,1}, jint, jint), [10,20], 1, 0)
    @test JavaCall.geterror() === nothing

    # JavaCall.JavaCallError("Error calling Java: java.lang.InstantiationException: java.util.AbstractCollection")
    @info "Expecting: \"Error calling Java: java.lang.InstantiationException: java.util.AbstractCollection\""
    @test_throws JavaCall.JavaCallError (@jimport java.util.AbstractCollection)()
    @test JavaCall.geterror() === nothing

    # JavaCall.JavaCallError("Error calling Java: java.lang.NoClassDefFoundError: java/util/Lis")
    @info "Expecting: \"Error calling Java: java.lang.NoClassDefFoundError: java/util/Lis\""
    @test_throws JavaCall.JavaCallError (@jimport java.util.Lis)()
    @test JavaCall.geterror() === nothing

    # JavaCall.JavaCallError("Error calling Java: java.lang.NoSuchMethodError: <init>")
    @info "Expecting: \"Error calling Java: java.lang.NoSuchMethodError: <init>\""
    @test_throws JavaCall.JavaCallError (@jimport java.util.ArrayList)((jboolean,), true)
    @test JavaCall.geterror() === nothing
end

end

@testset "fields_1" begin
    JTest = @jimport(Test)
    t=JTest(())
    t_fields = Dict(getname(f) => f for f in listfields(t))

    lazy_out = jfield(System, "out") # Not type stable
    @test jcall(System_out, "equals", jboolean, (JObject,), lazy_out) == 0x01

    @testset "$ftype" for (name, ftype, valtest) in [ ("booleanField", jboolean, ==(true)) ,
                                ("integerField", jint, ==(100)) ,
                                ("stringField", JString, ==("A STRING")) ,
                                ("objectField", JObject, x -> Ptr(x) == C_NULL) ]
        @test valtest(jfield(t, name, ftype))
        @test valtest(t_fields[name](t))
        @test valtest(jfield(t, t_fields[name]))
    end

    @test jfield(@jimport(java.lang.Math), "E", jdouble) == 2.718281828459045
    @test jfield(@jimport(java.lang.Math), "PI", jdouble) == 3.141592653589793
    @test jfield(@jimport(java.lang.Byte), "MAX_VALUE", jbyte) == 1<<7-1
    @test jfield(@jimport(java.lang.Integer), "MAX_VALUE", jint) == 1<<31-1
    @test jfield(@jimport(java.lang.Long), "MAX_VALUE", jlong) == 1<<63-1

    j_l_bool = @jimport(java.lang.Boolean)
    @test jcall(jfield(j_l_bool, "TRUE", j_l_bool), "booleanValue", jboolean, ()) == true
    @test jcall(jfield(j_l_bool, "FALSE", j_l_bool), "booleanValue", jboolean, ()) == false

    @test jfield(@jimport(java.text.NumberFormat), "INTEGER_FIELD", jint) == 0
    @test jfield(@jimport(java.util.logging.Logger), "GLOBAL_LOGGER_NAME", JString ) == "global"
    locale = @jimport java.util.Locale
    lc = jfield(locale, "CANADA", locale)
    @test jcall(lc, "getCountry", JString, ()) == "CA"
end

#Test NULL
@testset "null_1" begin
    H=@jimport java.util.HashMap
    a=jcall(T, "testNull", H, ())
    @test_throws JavaCall.JavaCallError jcall(a, "toString", JString, ())

    jlist = @jimport java.util.ArrayList
    @test jcall( jlist(), "add", jboolean, (JObject,), JObject(C_NULL)) === 0x01
    @test jcall( jlist(), "add", jboolean, (JObject,), JObject(JavaCall.J_NULL)) === 0x01
    @test jcall( jlist(), "add", jboolean, (JObject,), nothing) === 0x01
    @test jcall( System_out , "print", Nothing , (JObject,), JObject(C_NULL)) === nothing
    @test jcall( System_out , "print", Nothing , (JObject,), JObject(JavaCall.J_NULL)) === nothing
    @test jcall( System_out , "print", Nothing , (JObject,), nothing) === nothing
    @test jcall( System_out , "print", Nothing , (JString,), JString(C_NULL)) === nothing
    @test jcall( System_out , "print", Nothing , (JString,), JString(JavaCall.J_NULL)) === nothing
    @test jcall( System_out , "print", Nothing , (JString,), nothing) === nothing
end

@testset "arrays_1" begin
    j_u_arrays = @jimport java.util.Arrays
    @test 3 == jcall(j_u_arrays, "binarySearch", jint, (Array{jint,1}, jint), [10,20,30,40,50,60], 40)
    @test 2 == jcall(j_u_arrays, "binarySearch", jint, (Array{JObject,1}, JObject), ["123","abc","uvw","xyz"], "uvw")

    a=jcall(j_u_arrays, "copyOf", Array{jint, 1}, (Array{jint, 1}, jint), [1,2,3], 3)
    @test typeof(a) == Array{jint, 1}
    @test a[1] == Int32(1)
    @test a[2] == Int32(2)
    @test a[3] == Int32(3)

    a=jcall(j_u_arrays, "copyOf", Array{JObject, 1}, (Array{JObject, 1}, jint), ["a","b","c"], 3)
    @test 3==length(a)
    @test "a"==unsafe_string(convert(JString, a[1]))
    @test "b"==unsafe_string(convert(JString, a[2]))
    @test "c"==unsafe_string(convert(JString, a[3]))

    @test jcall(T, "testDoubleArray", Array{jdouble,1}, ()) == [0.1, 0.2, 0.3]
    @test jcall(T, "testDoubleArray2D", Array{Array{jdouble, 1},1}, ()) == [[0.1, 0.2, 0.3], [0.4, 0.5, 0.6]]
    @test jcall(T, "testDoubleArray2D", Array{jdouble,2}, ()) == [0.1 0.2 0.3; 0.4 0.5 0.6]
    @test size(jcall(T, "testStringArray2D", Array{JString,2}, ())) == (2,2)
end

@testset "jni_arrays_1" begin
    j_u_arrays = @jimport java.util.Arrays
    arr = jint[10,20,30,40,50,60]
    jniarr = JNIVector(arr)
    @test length(arr) == length(jniarr)
    @test size(arr) == size(jniarr)
    @test all(arr .== jniarr)
    @test 3 == jcall(j_u_arrays, "binarySearch", jint, (JNIVector{jint}, jint), jniarr, 40)
    @test "[10, 20, 30, 40, 50, 60]" == jcall(j_u_arrays, "toString", JString, (JavaCall.JNIVector{jint},), jniarr)

    JCharBuffer = @jimport(java.nio.CharBuffer)
    buf = jcall(JCharBuffer, "wrap", JCharBuffer, (JNIVector{jchar},), JNIVector(jchar.(collect("array"))))
    @test "array" == jcall(buf, "toString", JString, ())

    # Ensure JNIVectors are garbage collected properly
    # This used to be 1:100000
    @info "JNIVector GC test..."
    for i in 1:1000
        a = JNIVector(jchar[j == i ? 0 : 1 for j in 1:10000])
        buf = jcall(JCharBuffer, "wrap", JCharBuffer, (JNIVector{jchar},), a)
    end
    @info "JNIVector GC test complete."
end

@testset "dates_1" begin
    jd = @jimport(java.util.Date)(())
    jcal = @jimport(java.util.GregorianCalendar)(())
    jsd =  @jimport(java.sql.Date)((jlong,),round(jlong, time()))

    @test typeof(convert(Dates.DateTime, jd)) == Dates.DateTime
    @test typeof(convert(Dates.DateTime, jcal)) == Dates.DateTime
    @test typeof(convert(Dates.DateTime, jsd)) == Dates.DateTime
    nulldate = @jimport(java.util.Date)(C_NULL)
    @test Dates.year(convert(Dates.DateTime, nulldate)) == 1970
    nullcal = @jimport(java.util.GregorianCalendar)(C_NULL)
    @test Dates.year(convert(Dates.DateTime, nullcal)) == 1970

    @test Dates.year(convert(Dates.DateTime, nullcal)) == 1970
end

@testset "map_conversion_1" begin
    JHashMap = @jimport(java.util.HashMap)
    p = JHashMap(())
    a= Dict("a"=>"A", "b"=>"B")
    b=convert(@jimport(java.util.Map), JString, JString, a)
    @test jcall(b, "size", jint, ()) == 2
end

@testset "array_list_conversion_1" begin
    JArrayList = @jimport(java.util.ArrayList)
    p = JArrayList(())
    a = ["hello", " ", "world"]
    b = convert(@jimport(java.util.ArrayList), a, JString)
    @test jcall(b, "size", jint, ()) == 3
end

@testset "inner_classes_1" begin
    TestInner = @jimport(Test$TestInner)
    JTest = @jimport(Test)
    t=JTest(())
    inner = TestInner((JTest,), t)
    @test jcall(inner, "innerString", JString, ()) == "from inner"
end

# Test Memory allocation and de-allocatios
# the following loop fails with an OutOfMemoryException in the absence of de-allocation
# However, since Java and Julia memory are not linked, and manual gc() is required.
gc()
for i in 1:100000
    a=JString("A"^10000); #deleteref(a);
    if (i%10000 == 0); gc(); end
end

@testset "sinx_1" begin
    @test_throws UndefVarError jcall(jlm, "sinx", jdouble, (jdouble,), 1.0)
    @test_throws UndefVarError jcall(jlm, "sinx", jdouble, (jdouble,), 1.0)
end

@testset "method_lists_1" begin
    @test length(listmethods(JString("test"))) >= 72
    @test length(listmethods(JString("test"), "indexOf")) >= 3
    # the same for the type
    @test length(listmethods(JString)) >= 72
    @test length(listmethods(JString, "indexOf")) >= 3
    # the same for class
    @test length(listmethods(getclass(JString("test")))) >= 72
    @test length(listmethods(getclass(JString("test")), "indexOf")) >= 3
    m = listmethods(JString("test"), "indexOf")
    @test getname(getreturntype(m[1])) == "int"

    z = [getname.(t) for t in getparametertypes.(m)]
    @test findfirst(n->n==["int"], z) != nothing
    @test findfirst(n->n==["java.lang.String", "int"], z) != nothing
end

#Test for double free bug, #20
#Fix in #28. The following lines will segfault without the fix
@testset "double_free_1" begin
    JHashtable = @jimport java.util.Hashtable
    JProperties = @jimport java.util.Properties
    ta_20=Any[]
    for i=1:100; push!(ta_20, convert(JHashtable, JProperties((),))); end
    gc(); gc()
    for i=1:100; @test jcall(ta_20[i], "size", jint, ()) == 0; end
end

@testset "array_conversions_1" begin
    jobj = jcall(T, "testArrayAsObject", JObject, ())
    arr = convert(Array{Array{UInt8, 1}, 1}, jobj)
    @test ["Hello", "World"] == map(String, arr)
end

@testset "iterator_conversions_1" begin
    JArrayList = @jimport(java.util.ArrayList)
    a=JArrayList(())
    jcall(a, "add", jboolean, (JObject,), "abc")
    jcall(a, "add", jboolean, (JObject,), "cde")
    jcall(a, "add", jboolean, (JObject,), "efg")

    t=Array{Any, 1}()
    for i in JavaCall.iterator(a)
        push!(t, unsafe_string(i))
    end

    @test length(t) == 3
    @test t[1] == "abc"
    @test t[2] == "cde"
    @test t[3] == "efg"

    #Different iterator type - ListIterator
    t=Array{Any, 1}()
    for i in jcall(a, "listIterator", @jimport(java.util.ListIterator), ())
        push!(t, unsafe_string(i))
    end

    @test length(t) == 3
    @test t[1] == "abc"
    @test t[2] == "cde"
    @test t[3] == "efg"

    a=JArrayList(())
    t=Array{Any, 1}()
    for i in JavaCall.iterator(a)
        push!(t, unsafe_string(i))
    end
    @test length(t) == 0

    JStringClass = classforname("java.lang.String")
    @test isa(JStringClass, JavaObject{Symbol("java.lang.Class")})

    o = convert(JObject, "bla bla bla")
    @test isa(narrow(o), JString)
end

@testset "roottask_and_env_1" begin
    @test JavaCall.isroottask()
    @testasync ! JavaCall.isroottask()
    @test JavaCall.isgoodenv()
    if JAVACALL_FORCE_ASYNC_TEST || JavaCall.JULIA_COPY_STACKS || Sys.iswindows()
        @testasync JavaCall.isgoodenv()
    end
    if ! JavaCall.JULIA_COPY_STACKS && ! Sys.iswindows()
        @test_throws CompositeException @syncasync JavaCall.assertroottask_or_goodenv()
        @warn "Ran tests for root Task only." *
            " REPL and @async are not expected to work with JavaCall without JULIA_COPY_STACKS=1" *
            " on non-Windows systems."
            " Set JULIA_COPY_STACKS=1 in the environment to test @async function."
    end
end

@testset "jlocalframe" begin
    @test jlocalframe() do
        JObject()
    end isa JObject
    @test jlocalframe() do 
        5
    end isa Int64
    @test_throws ErrorException jlocalframe() do 
        error("Error within jlocalframe f")
    end

    @test jlocalframe(JObject) do T
        T()
    end isa JObject
    @test jlocalframe(UInt64) do T
        T(6)
    end isa UInt64
    @test_throws ErrorException jlocalframe(JObject) do T
        error("Error within jlocalframe f")
    end

    @test jlocalframe(Nothing) do 
        JObject() 
    end === nothing
    @test_throws ErrorException jlocalframe(Nothing) do 
        error("Error within jlocalframe f")
    end
end

end

# Test downstream dependencies
try
    using Pkg
    Pkg.add("Taro")

    using Taro
    chmod(joinpath(dirname(dirname(pathof(Taro))),"test","df-test.xlsx"),0o600)

    Pkg.test("Taro")
    #include(joinpath(dirname(dirname(pathof(Taro))),"test","runtests.jl"))
catch err
    @warn "Taro.jl testing failed"
    sprint(showerror, err, backtrace())
end

# Run GC before we destroy to avoid errors
GC.gc()
# At the end, unload the JVM before exiting
JavaCall.destroy()
