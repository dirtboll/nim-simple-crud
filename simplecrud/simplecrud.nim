import 
  jester,
  norm/[model, sqlite],
  std/[os, macros, options, strutils, sugar, logging, httpcore, marshal, asyncdispatch]

type 
  # Override RouteError from Jester to access exc and data
  # Apparently when naming this to original "RouteError", 
  # `errorHandler` failed to be registered to Jester.
  MyRouteError = object
    case kind: RouteErrorKind
    of RouteException:
      exc: ref Exception
    of RouteCode:
      data: ResponseData

  # Wrapper for all responses
  BaseResponse*[T] = object
    success*: bool
    message*: string
    data*: T
  
  Student* = ref object of Model
    nama*: string
    alamat*: string
    npm*: string

  StudentDto* = object
    nama*: string
    alamat*: string
    npm*: string

# BaseResponse's constructor
func newBaseResponse*[T](success: bool = true, message: string = "Operation Success", data: T = newSeq[string]()): BaseResponse[T] =
  result.success = success
  result.message = message
  result.data = data

# Student's constructor
func newStudent*(nama: string = "", alamat: string = "", npm: string = ""): Student = 
  Student(nama: nama, alamat: alamat, npm: npm)


func toStudent*(studentDto: StudentDto): Student =
  new result
  result.nama = studentDto.nama
  result.alamat = studentDto.alamat
  result.npm = studentDto.npm

func toStudentDto*(student: Student): StudentDto =
  result.nama = student.nama
  result.alamat = student.alamat
  result.npm = student.npm

#[
  Macro for sending json response with message based on HTTP Code.
  If `msg` blank, "Opration Success" is sent for success HTTP codes, 
  else HTTP status message is sent.
]#
template jsonResp[T](httpCode: HttpCode, msg: string = "", data: T = newSeq[int]()) =
  var fail = httpCode.is4xx or httpCode.is5xx
  var message = if msg != "": msg elif fail: ($httpCode)[4..^1] else: "Opration Success"
  resp httpCode, $$newBaseResponse(not fail, message, data), "application/json"

#[
  Macro to check Content-Type header from `nama`.
  "Unsupported Media-Type" is sent if assertion fails.
]#
template assertContentType(nama: string) =
  var found = false
  for val in seq[string](headers(request).getOrDefault("Content-Type")):
    if val.toLowerAscii.contains(nama.toLowerAscii):
      found = true
      break
  if not found:
    jsonResp Http415

#[
  Error handler to override Jester's defaultErrorFilter and wrap
  responses in BaseResponse.
]#
proc errorHandler(request: Request, err: RouteError): Future[ResponseData] {.async.} =
  var error = cast[MyRouteError](err) # Prevent compiler crying
  case error.kind:
  of RouteException:
    var traceback = getStackTrace(error.exc)
    var errorMsg = error.exc.msg
    if errorMsg.len == 0: errorMsg = "(empty)"
    logging.error(traceback & errorMsg)
    return (
      TCActionSend, 
      Http502, 
      some(@({"Content-Type": "application/json"})), 
      $$newBaseResponse(false, "Route Error"), 
      true
    )
  of RouteCode:
    return (
      TCActionSend, 
      error.data.code, 
      some(@({"Content-Type": "application/json"})), 
      $$newBaseResponse(false, 
      ($error.data.code)[4 .. ^1]), 
      true
    )

# Norm's database connection
var dbConn: DbConn

# Jester's routing declaration
router myrouter:

  #[
    (Get student's data from npm)
    GET /mahasiswa/<npm>
  ]#
  get "/mahasiswa/@npm":
    var studentDb = newStudent()
    try:
      dbConn.select(studentDb, "Student.npm = ?", @"npm")
    except:
      jsonResp Http404, "Student Not Found"
    jsonResp Http200, "", studentDb.toStudentDto

  #[
    (Input student data)
    POST /mahasiswa
    Headers:
      Content-Type: application/json
    Body:
      {
        "nama": <name>,
        "alamat": <address>,
        "npm": <npm>
      }
  ]#
  post "/mahasiswa":
    assertContentType "application/json"
    var student: Student
    try:
      student = request.body.to[:StudentDto].toStudent    
    except:
      jsonResp Http400
    if student.nama == "" or student.npm == "" or student.alamat == "":
      jsonResp Http400
    if dbConn.exists(Student, "npm = ?", student.npm):
      jsonResp Http400, "Student Exists"
    {.cast(gcsafe).}: # Cheeky hack
      dbConn.insert(student)
    jsonResp Http201

  #[
    (Update student data)
    PUT /mahasiswa/<npm>
    Headers:
      Content-Type: application/json
    Body:
      {
        "nama": <name>,
        "alamat": <address>
      }
  ]#
  put "/mahasiswa/@npm":
    assertContentType "application/json"
    var student: Student
    try:
      student = request.body.to[:StudentDto].toStudent    
    except:
      jsonResp Http400
    if student.nama == "" or student.alamat == "":
      jsonResp Http400
    var studentDb = newStudent()
    try:
      dbConn.select(studentDb, "Student.npm = ?", @"npm")
    except:
      jsonResp Http404, "Student Not Found"
    student.id = studentDb.id
    student.npm = studentDb.npm
    {.cast(gcsafe).}:
      dbConn.update(student)
    jsonResp Http200
  
  #[
    (Delete student data)
    DELETE /mahasiswa/<npm>
  ]#
  delete "/mahasiswa/@npm":
    var studentDb = newStudent()
    try:
      dbConn.select(studentDb, "Student.npm = ?", @"npm")
    except:
      jsonResp Http404, "Student Not Found"
    {.cast(gcsafe).}:
      dbConn.delete(studentDb)
    jsonResp Http200

  #[
    (Upload a file)
    Headers:
      Content-Type: multipart/form-data
    Body:
      file=<data>
  ]#
  post "/upload":
    assertContentType "multipart/form-data"
    var formData = request.formData.getOrDefault("file")
    var filename = formData.fields.getOrDefault("filename", "file")
    writeFile(filename, formData.body)
    jsonResp Http200

# Entrypoint if run as standalone binary
proc main() =
  var port = 8080.Port
  try: port = paramStr(1).parseInt().Port
  except: discard
  let settings = newSettings(port=port)
  var jester = initJester(myrouter, settings=settings)
  jester.register(errorHandler)
  dbConn = open("db.sqlite", "", "", "")
  dbConn.createTables(newStudent())
  jester.serve()

when(isMainModule):
  main()