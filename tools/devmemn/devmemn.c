typedef unsigned long u64; typedef unsigned int u32;
static long sys(long n,long a,long b,long c,long d,long e,long f){
  register long x8 __asm__("x8")=n,x0 __asm__("x0")=a,x1 __asm__("x1")=b,
   x2 __asm__("x2")=c,x3 __asm__("x3")=d,x4 __asm__("x4")=e,x5 __asm__("x5")=f;
  __asm__ volatile("svc 0":"+r"(x0):"r"(x8),"r"(x1),"r"(x2),"r"(x3),"r"(x4),"r"(x5):"memory");
  return x0;
}
#define SYS_openat 56
#define SYS_mmap 222
#define SYS_write 64
#define SYS_exit 93
static int slen(const char*s){int n=0;while(s[n])n++;return n;}
static u64 xtoull(const char*s){u64 v=0;if(s[0]=='0'&&(s[1]=='x'||s[1]=='X'))s+=2;
  while(*s){char c=*s++;u64 d;if(c>='0'&&c<='9')d=c-'0';else if(c>='a'&&c<='f')d=c-'a'+10;
  else if(c>='A'&&c<='F')d=c-'A'+10;else break;v=v*16+d;}return v;}
static void phex(u32 v){char b[11];for(int i=0;i<8;i++){int n=(v>>((7-i)*4))&0xf;b[2+i]=n<10?'0'+n:'a'+n-10;}b[0]='0';b[1]='x';b[10]='\n';sys(SYS_write,1,(long)b,11,0,0,0);}
__asm__(".global _start\n_start:\n  mov x0, sp\n  b real_start\n");
void real_start(long*st){
  long argc=st[0]; char**argv=(char**)&st[1];
  if(argc<2){const char*m="usage: devmemn ADDR [VAL]\n";sys(SYS_write,2,(long)m,slen(m),0,0,0);sys(SYS_exit,1,0,0,0,0,0);}
  u64 addr=xtoull(argv[1]); u64 page=addr&~0xFFFUL,off=addr&0xFFF;
  int wr=argc>2;
  const char*dev="/dev/mem";
  long fd=sys(SYS_openat,-100,(long)dev,wr?2:0,0,0,0);
  if(fd<0){const char*m="open fail\n";sys(SYS_write,2,(long)m,slen(m),0,0,0);sys(SYS_exit,2,0,0,0,0,0);}
  long pr=wr?3:1;
  void*m=(void*)sys(SYS_mmap,0,0x1000,pr,1,fd,page);
  if((long)m<0){const char*e="mmap fail\n";sys(SYS_write,2,(long)e,slen(e),0,0,0);sys(SYS_exit,3,0,0,0,0,0);}
  volatile u32*p=(volatile u32*)((char*)m+off);
  if(wr)*p=(u32)xtoull(argv[2]);
  phex(*p);
  sys(SYS_exit,0,0,0,0,0,0);
}
