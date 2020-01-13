MODULE FIRE
 
! Compute combustion
 
USE PRECISION_PARAMETERS
USE GLOBAL_CONSTANTS
USE MESH_POINTERS
USE COMP_FUNCTIONS, ONLY: SECOND
 
IMPLICIT NONE
PRIVATE
   
CHARACTER(255), PARAMETER :: fireid='$Id: fire.f90 19141 2014-05-02 17:33:10Z randy.mcdermott $'
CHARACTER(255), PARAMETER :: firerev='$Revision: 19141 $'
CHARACTER(255), PARAMETER :: firedate='$Date: 2014-05-02 12:33:10 -0500 (vie 02 de may de 2014) $'

TYPE(REACTION_TYPE), POINTER :: RN=>NULL()
REAL(EB) :: Q_UPPER
LOGICAL :: EXTINCT = .FALSE.

PUBLIC COMBUSTION, GET_REV_fire

CONTAINS
 
SUBROUTINE COMBUSTION(NM)

INTEGER, INTENT(IN) :: NM
REAL(EB) :: TNOW

IF (EVACUATION_ONLY(NM)) RETURN

TNOW=SECOND()

IF (INIT_HRRPUV) RETURN

CALL POINT_TO_MESH(NM)

! Upper bounds on local HRR per unit volume

Q_UPPER = HRRPUA_SHEET/CELL_SIZE + HRRPUV_AVERAGE

! Call combustion ODE solver

CALL COMBUSTION_GENERAL

TUSED(10,NM)=TUSED(10,NM)+SECOND()-TNOW

END SUBROUTINE COMBUSTION


SUBROUTINE COMBUSTION_GENERAL

! Generic combustion routine for multi-step reactions

USE PHYSICAL_FUNCTIONS, ONLY: GET_SPECIFIC_GAS_CONSTANT,GET_MASS_FRACTION_ALL,GET_SPECIFIC_HEAT,GET_MOLECULAR_WEIGHT, &
                              GET_SENSIBLE_ENTHALPY_DIFF,GET_SENSIBLE_ENTHALPY
INTEGER :: I,J,K,NS,NR,II,JJ,KK,IIG,JJG,KKG,IW,N
REAL(EB):: ZZ_GET(0:N_TRACKED_SPECIES),DZZ(0:N_TRACKED_SPECIES),CP,HDIFF
LOGICAL :: Q_EXISTS
TYPE (REACTION_TYPE), POINTER :: RN
TYPE (SPECIES_MIXTURE_TYPE), POINTER :: SM,SM0

Q          = 0._EB
D_REACTION = 0._EB
Q_EXISTS = .FALSE.
SM0 => SPECIES_MIXTURE(0)

!$OMP PARALLEL DEFAULT(NONE) &
!$OMP SHARED(KBAR,JBAR,IBAR,SOLID,CELL_INDEX,N_TRACKED_SPECIES,N_REACTIONS,REACTION,COMBUSTION_ODE,Q,RSUM,TMP,PBAR, &
!$OMP        PRESSURE_ZONE,RHO,ZZ,D_REACTION,SPECIES_MIXTURE,SM0,DT,CONSTANT_SPECIFIC_HEAT_RATIO)

!$OMP DO SCHEDULE(STATIC) COLLAPSE(3)&
!$OMP PRIVATE(K,J,I,ZZ_GET,DO_REACTION,NR,RN,REACTANTS_PRESENT,ZZ_MIN,Q_EXISTS,SM,CP,HDIFF,DZZ)

DO K=1,KBAR
   DO J=1,JBAR
      ILOOP: DO I=1,IBAR
         !Check to see if a reaction is possible
         IF (SOLID(CELL_INDEX(I,J,K))) CYCLE ILOOP
         ZZ_GET(1:N_TRACKED_SPECIES) = ZZ(I,J,K,1:N_TRACKED_SPECIES)
         ZZ_GET(0) = 1._EB - MIN(1._EB,SUM(ZZ_GET(1:N_TRACKED_SPECIES)))
         IF (.NOT.DO_REACTION()) CYCLE ILOOP ! Check whether any reactions are possible.
         DZZ(1:N_TRACKED_SPECIES) = ZZ_GET(1:N_TRACKED_SPECIES) ! store old ZZ for divergence term
         ! Call combustion integration routine
         CALL COMBUSTION_MODEL(I,J,K,ZZ_GET,Q(I,J,K))
         ! Update RSUM and ZZ
         DZZ_IF: IF ( ANY(ABS(DZZ) > TWO_EPSILON_EB) ) THEN
            IF (ABS(Q(I,J,K)) > TWO_EPSILON_EB) Q_EXISTS = .TRUE.
            CALL GET_SPECIFIC_GAS_CONSTANT(ZZ_GET,RSUM(I,J,K)) 
            TMP(I,J,K) = PBAR(K,PRESSURE_ZONE(I,J,K))/(RSUM(I,J,K)*RHO(I,J,K))
            ZZ(I,J,K,1:N_TRACKED_SPECIES) = ZZ_GET(1:N_TRACKED_SPECIES)
            CP_IF: IF (.NOT.CONSTANT_SPECIFIC_HEAT_RATIO) THEN
               ! Divergence term
               DZZ(1:N_TRACKED_SPECIES) = ZZ_GET(1:N_TRACKED_SPECIES) - DZZ(1:N_TRACKED_SPECIES)
               CALL GET_SPECIFIC_HEAT(ZZ_GET,CP,TMP(I,J,K))
               DO N=1,N_TRACKED_SPECIES
                  SM => SPECIES_MIXTURE(N)
                  CALL GET_SENSIBLE_ENTHALPY_DIFF(N,TMP(I,J,K),HDIFF)
                  D_REACTION(I,J,K) = D_REACTION(I,J,K) + ( (SM%RCON-SM0%RCON)/RSUM(I,J,K) - HDIFF/(CP*TMP(I,J,K)) )*DZZ(N)/DT
               ENDDO
            ENDIF CP_IF
         ENDIF DZZ_IF
      ENDDO ILOOP
   ENDDO
ENDDO
!$OMP END DO
!$OMP END PARALLEL

IF (.NOT.Q_EXISTS) RETURN

! Set Q in the ghost cell, just for better visualization.

DO IW=1,N_EXTERNAL_WALL_CELLS
   IF (WALL(IW)%BOUNDARY_TYPE/=INTERPOLATED_BOUNDARY .AND. WALL(IW)%BOUNDARY_TYPE/=OPEN_BOUNDARY) CYCLE
   II  = WALL(IW)%ONE_D%II
   JJ  = WALL(IW)%ONE_D%JJ
   KK  = WALL(IW)%ONE_D%KK
   IIG = WALL(IW)%ONE_D%IIG
   JJG = WALL(IW)%ONE_D%JJG
   KKG = WALL(IW)%ONE_D%KKG
   Q(II,JJ,KK) = Q(IIG,JJG,KKG)
ENDDO

CONTAINS

LOGICAL FUNCTION DO_REACTION()
LOGICAL :: REACTANTS_PRESENT
! Check whether any reactions are possible.
DO_REACTION = .FALSE.
REACTION_LOOP: DO NR=1,N_REACTIONS
   RN=>REACTION(NR)
   REACTANTS_PRESENT = .TRUE.
      DO NS=0,N_TRACKED_SPECIES
         IF (RN%NU(NS)<0._EB .AND. ZZ_GET(NS) < ZZ_MIN_GLOBAL) THEN
            REACTANTS_PRESENT = .FALSE.
            EXIT
         ENDIF
      END DO
    DO_REACTION = REACTANTS_PRESENT
    IF (DO_REACTION) EXIT REACTION_LOOP
END DO REACTION_LOOP

END FUNCTION DO_REACTION

END SUBROUTINE COMBUSTION_GENERAL


SUBROUTINE COMBUSTION_MODEL(I,J,K,ZZ_GET,Q_OUT)
USE COMP_FUNCTIONS, ONLY: SHUTDOWN
USE PHYSICAL_FUNCTIONS, ONLY: LES_FILTER_WIDTH_FUNCTION,GET_AVERAGE_SPECIFIC_HEAT,GET_SPECIFIC_GAS_CONSTANT
USE RADCONS, ONLY: RADIATIVE_FRACTION
INTEGER, INTENT(IN) :: I,J,K
REAL(EB), INTENT(OUT) :: Q_OUT
REAL(EB), INTENT(INOUT) :: ZZ_GET(0:N_TRACKED_SPECIES)
REAL(EB) :: ERR_EST,ERR_TOL,ZZ_TEMP(0:N_TRACKED_SPECIES),&
            A1(0:N_TRACKED_SPECIES),A2(0:N_TRACKED_SPECIES),A4(0:N_TRACKED_SPECIES),Q_SUM,Q_CUM,ZETA,ZETA_0,&
            DT_SUB,DT_SUB_NEW,DT_ITER,ZZ_STORE(0:N_TRACKED_SPECIES,0:3),TV(0:2,0:N_TRACKED_SPECIES),CELL_VOLUME,CELL_MASS,&
            ZZ_DIFF(0:2,0:N_TRACKED_SPECIES),ZZ_MIXED(0:N_TRACKED_SPECIES),ZZ_UNMIXED(0:N_TRACKED_SPECIES),&
            ZZ_MIXED_NEW(0:N_TRACKED_SPECIES),TAU_D,TAU_G,TAU_U,TAU_MIX,DELTA,TMP_MIXED,DT_SUB_MIN,RHO_HAT
INTEGER :: NR,NS,ITER,TVI,RICH_ITER,TIME_ITER,SR
INTEGER, PARAMETER :: TV_ITER_MIN=5,RICH_ITER_MAX=5
LOGICAL :: TV_FLUCT(0:N_TRACKED_SPECIES)
TYPE(REACTION_TYPE), POINTER :: RN=>NULL()

IF (FIXED_MIX_TIME>0._EB) THEN
   MIX_TIME(I,J,K)=FIXED_MIX_TIME
ELSE
   DELTA = LES_FILTER_WIDTH_FUNCTION(DX(I),DY(J),DZ(K))
   TAU_D=0._EB
   DO NR =1,N_REACTIONS
      RN => REACTION(NR)
      TAU_D = MAX(TAU_D,D_Z(MIN(4999,NINT(TMP(I,J,K))),RN%FUEL_SMIX_INDEX))
   ENDDO
   TAU_D = DELTA**2/TAU_D ! FDS Tech Guide (5.21)
   IF (LES) THEN
      TAU_U = C_DEARDORFF*SC*RHO(I,J,K)*DELTA**2/MU(I,J,K)            ! FDS Tech Guide (5.22)
      TAU_G = SQRT(2._EB*DELTA/(GRAV+1.E-10_EB))                      ! FDS Tech Guide (5.23)
      MIX_TIME(I,J,K)= MAX(TAU_CHEM,MIN(TAU_D,TAU_U,TAU_G,TAU_FLAME)) ! FDS Tech Guide (5.20)
   ELSE
      MIX_TIME(I,J,K)= MAX(TAU_CHEM,TAU_D)
   ENDIF
ENDIF

DT_SUB_MIN = DT/REAL(MAX_CHEMISTRY_ITERATIONS,EB)
ZZ_STORE(:,:) = 0._EB
Q_OUT = 0._EB
Q_CUM = 0._EB
Q_SUM = 0._EB
ITER= 0
DT_ITER = 0._EB
DT_SUB = DT 
DT_SUB_NEW = DT
ZZ_UNMIXED = ZZ_GET
ZZ_TEMP = ZZ_GET
ZZ_MIXED = ZZ_GET
A1 = ZZ_GET
A2 = ZZ_GET
A4 = ZZ_GET
ZETA_0 = INITIAL_UNMIXED_FRACTION
ZETA = ZETA_0
CELL_VOLUME = DX(I)*DY(J)*DZ(K)
CELL_MASS = RHO(I,J,K)*CELL_VOLUME
RHO_HAT = RHO(I,J,K)
TMP_MIXED = TMP(I,J,K)
TAU_MIX = MIX_TIME(I,J,K)
EXTINCT = .FALSE.

INTEGRATION_LOOP: DO TIME_ITER = 1,MAX_CHEMISTRY_ITERATIONS

   IF (SUPPRESSION .AND. TIME_ITER==1) EXTINCT = FUNC_EXTINCT(ZZ_MIXED,TMP_MIXED)

   INTEGRATOR_SELECT: SELECT CASE (COMBUSTION_ODE_SOLVER)

      CASE (EXPLICIT_EULER) ! Simple chemistry

         DO SR=0,N_SERIES_REACTIONS
            CALL FIRE_FORWARD_EULER(ZZ_MIXED_NEW,ZETA,ZZ_MIXED,ZETA_0,DT_SUB,TMP_MIXED,RHO_HAT,ZZ_UNMIXED,CELL_MASS,TAU_MIX)
            ZZ_MIXED = ZZ_MIXED_NEW
         ENDDO         
         IF (TIME_ITER > 1) CALL SHUTDOWN('ERROR: Error in Simple Chemistry')

      CASE (RK2_RICHARDSON) ! Finite-rate (or mixed finite-rate/fast) chemistry

         ERR_TOL = RICHARDSON_ERROR_TOLERANCE
         RICH_EX_LOOP: DO RICH_ITER = 1,RICH_ITER_MAX
            DT_SUB = MIN(DT_SUB_NEW,DT-DT_ITER)           

            CALL FIRE_RK2(A1,ZETA,ZZ_MIXED,ZETA_0,DT_SUB,1,TMP_MIXED,RHO_HAT,ZZ_UNMIXED,CELL_MASS,TAU_MIX) ! FDS Tech Guide (E.3)
            CALL FIRE_RK2(A2,ZETA,ZZ_MIXED,ZETA_0,DT_SUB,2,TMP_MIXED,RHO_HAT,ZZ_UNMIXED,CELL_MASS,TAU_MIX) ! FDS Tech Guide (E.4)
            CALL FIRE_RK2(A4,ZETA,ZZ_MIXED,ZETA_0,DT_SUB,4,TMP_MIXED,RHO_HAT,ZZ_UNMIXED,CELL_MASS,TAU_MIX) ! FDS Tech Guide (E.5)

            ! Species Error Analysis
            ERR_EST = MAXVAL(ABS((4._EB*A4-5._EB*A2+A1)))/45._EB ! FDS Tech Guide (E.7)
            DT_SUB_NEW = MIN(MAX(DT_SUB*(ERR_TOL/(ERR_EST+TWO_EPSILON_EB))**(0.25_EB),DT_SUB_MIN),DT-DT_ITER) ! (E.8)
            IF (RICH_ITER == RICH_ITER_MAX) EXIT RICH_EX_LOOP
            IF (ERR_EST <= ERR_TOL) EXIT RICH_EX_LOOP
         ENDDO RICH_EX_LOOP
         ZETA_0 = ZETA
         ZZ_MIXED = (4._EB*A4-A2)*ONTH ! FDS Tech Guide (E.6)

   END SELECT INTEGRATOR_SELECT

   ZZ_GET =  ZETA*ZZ_UNMIXED + (1._EB-ZETA)*ZZ_MIXED ! FDS Tech Guide (5.30)
   DT_ITER = DT_ITER + DT_SUB
   ITER = ITER + 1
   IF (OUTPUT_CHEM_IT) THEN
      CHEM_SUBIT(I,J,K) = ITER
   ENDIF

   ! Compute heat release rate
   
   Q_SUM = 0._EB
   IF (MAXVAL(ABS(ZZ_GET-ZZ_TEMP)) > TWO_EPSILON_EB) THEN
      Q_SUM = Q_SUM - RHO(I,J,K)*SUM(SPECIES_MIXTURE%H_F*(ZZ_GET-ZZ_TEMP)) ! FDS Tech Guide (5.14)
   ENDIF
   IF (Q_CUM + Q_SUM > Q_UPPER*DT) THEN
      Q_OUT = Q_UPPER
      ZZ_GET = ZZ_TEMP + (Q_UPPER*DT/(Q_CUM + Q_SUM))*(ZZ_GET-ZZ_TEMP)
      EXIT INTEGRATION_LOOP
   ELSE
      Q_CUM = Q_CUM+Q_SUM
      Q_OUT = Q_CUM/DT
   ENDIF
   
   ! Total Variation (TV) scheme (accelerates integration for finite-rate equilibrium calculations)
   ! See FDS Tech Guide Appendix E
   
   IF (COMBUSTION_ODE_SOLVER==RK2_RICHARDSON .AND. N_REACTIONS > 1) THEN
      DO NS = 0,N_TRACKED_SPECIES
         DO TVI = 0,2
            ZZ_STORE(NS,TVI)=ZZ_STORE(NS,TVI+1)
         ENDDO
         ZZ_STORE(NS,3) = ZZ_GET(NS)
      ENDDO
      TV_FLUCT(:) = .FALSE.
      IF (ITER >= TV_ITER_MIN) THEN
         SPECIES_LOOP_TV: DO NS = 0,N_TRACKED_SPECIES
            DO TVI = 0,2
               TV(TVI,NS) = ABS(ZZ_STORE(NS,TVI+1)-ZZ_STORE(NS,TVI))
               ZZ_DIFF(TVI,NS) = ZZ_STORE(NS,TVI+1)-ZZ_STORE(NS,TVI)
            ENDDO
            IF (SUM(TV(:,NS)) < ERR_TOL .OR. SUM(TV(:,NS)) >= ABS(2.9_EB*SUM(ZZ_DIFF(:,NS)))) THEN ! FDS Tech Guide (E.10)
               TV_FLUCT(NS) = .TRUE.
            ENDIF
            IF (ALL(TV_FLUCT)) EXIT INTEGRATION_LOOP
         ENDDO SPECIES_LOOP_TV
      ENDIF
   ENDIF

   ZZ_TEMP = ZZ_GET
   IF ( DT_ITER > (DT-TWO_EPSILON_EB) ) EXIT INTEGRATION_LOOP

ENDDO INTEGRATION_LOOP

!~ IF (REAC_SOURCE_CHECK) REAC_SOURCE_TERM(I,J,K,:) = (ZZ_UNMIXED(1:N_TRACKED_SPECIES)-ZZ_GET(1:N_TRACKED_SPECIES))*CELL_MASS/DT ! store special output quantity
IF (REAC_SOURCE_CHECK) REAC_SOURCE_TERM(I,J,K,:) = (ZZ_UNMIXED(1:N_TRACKED_SPECIES)-ZZ_GET(1:N_TRACKED_SPECIES))*RHO(I,J,K)/DT ! store special output quantity (kg/m3/s)

!~ WRITE(LU_ERR,*) 'SP 3 ', SPECIES_MIXTURE(3)%ID
!~ WRITE(LU_ERR,*) 'r ', REAC_SOURCE_TERM(I,J,K,:)
!~ WRITE(LU_ERR,*) 'r3 ', REAC_SOURCE_TERM(I,J,K,3)
END SUBROUTINE COMBUSTION_MODEL


SUBROUTINE FIRE_FORWARD_EULER(ZZ_OUT,ZETA_OUT,ZZ_IN,ZETA_IN,DT_LOC,TMP_MIXED,RHO_HAT,ZZ_UNMIXED,CELL_MASS,TAU_MIX)
USE COMP_FUNCTIONS, ONLY:SHUTDOWN
REAL(EB), INTENT(IN) :: ZZ_IN(0:N_TRACKED_SPECIES),ZETA_IN,DT_LOC,TMP_MIXED,RHO_HAT,ZZ_UNMIXED(0:N_TRACKED_SPECIES),CELL_MASS,&
                        TAU_MIX
REAL(EB), INTENT(OUT) :: ZZ_OUT(0:N_TRACKED_SPECIES),ZETA_OUT
REAL(EB) :: ZZ_0(0:N_TRACKED_SPECIES),ZZ_NEW(0:N_TRACKED_SPECIES),DZZ(0:N_TRACKED_SPECIES),UNMIXED_MASS_0(0:N_TRACKED_SPECIES),&
            BOUNDEDNESS_CORRECTION,MIXED_MASS(0:N_TRACKED_SPECIES),MIXED_MASS_0(0:N_TRACKED_SPECIES),TOTAL_MIXED_MASS
INTEGER :: SR
INTEGER, PARAMETER :: INFINITELY_FAST=1,FINITE_RATE=2

ZETA_OUT = ZETA_IN*EXP(-DT_LOC/TAU_MIX) ! FDS Tech Guide (5.29)
IF (ZETA_OUT < TWO_EPSILON_EB) ZETA_OUT = 0._EB
MIXED_MASS_0 = CELL_MASS*ZZ_IN
UNMIXED_MASS_0 = CELL_MASS*ZZ_UNMIXED
MIXED_MASS = MAX(0._EB,MIXED_MASS_0 - (ZETA_OUT - ZETA_IN)*UNMIXED_MASS_0) ! FDS Tech Guide (5.37)
TOTAL_MIXED_MASS = SUM(MIXED_MASS)
ZZ_0 = MIXED_MASS/MAX(TOTAL_MIXED_MASS,TWO_EPSILON_EB) ! FDS Tech Guide (5.35)

IF (ANY(REACTION(:)%FAST_CHEMISTRY)) THEN
   DO SR = 0,N_SERIES_REACTIONS
      CALL REACTION_RATE(DZZ,ZZ_0,DT_LOC,RHO_HAT,TMP_MIXED,INFINITELY_FAST)
      ZZ_NEW = ZZ_0 + DZZ ! test Forward Euler step (5.53)
      BOUNDEDNESS_CORRECTION = FUNC_BCOR(ZZ_0,ZZ_NEW) ! Reaction rate boundedness correction
      ZZ_NEW = ZZ_0 + DZZ*BOUNDEDNESS_CORRECTION ! corrected FE step for all species (5.54)
      ZZ_0 = ZZ_NEW
   ENDDO
ENDIF

IF (.NOT.ALL(REACTION(:)%FAST_CHEMISTRY)) THEN
   CALL REACTION_RATE(DZZ,ZZ_0,DT_LOC,RHO_HAT,TMP_MIXED,FINITE_RATE)
   ZZ_NEW = ZZ_0 + DZZ
   BOUNDEDNESS_CORRECTION = FUNC_BCOR(ZZ_0,ZZ_NEW)
   ZZ_NEW = ZZ_0 + DZZ*BOUNDEDNESS_CORRECTION
ENDIF

! Enforce realizability on mass fractions

ZZ_NEW = MIN(MAX(ZZ_NEW,0._EB),1._EB)
ZZ_NEW(0) = 1._EB - MIN(1._EB,SUM(ZZ_NEW(1:N_TRACKED_SPECIES))) ! absorb errors in background species

ZZ_OUT = ZZ_NEW

END SUBROUTINE FIRE_FORWARD_EULER


REAL(EB) FUNCTION FUNC_BCOR(ZZ_0,ZZ_NEW)
! This function finds a correction for reaction rates such that all species remain bounded.

REAL(EB), INTENT(IN) :: ZZ_0(0:N_TRACKED_SPECIES),ZZ_NEW(0:N_TRACKED_SPECIES)
REAL(EB) :: BCOR,DZ_IB,DZ_OB
INTEGER :: NS

BCOR = 1._EB
DO NS=0,N_TRACKED_SPECIES
   IF (ZZ_NEW(NS)<0._EB) THEN ! FDS Tech Guide (5.55)
      DZ_IB=ZZ_0(NS)        ! DZ "in bounds"
      DZ_OB=ABS(ZZ_NEW(NS)) ! DZ "out of bounds"
      BCOR = MIN( BCOR, DZ_IB/MAX(DZ_IB+DZ_OB,TWO_EPSILON_EB) )
   ENDIF
   IF (ZZ_NEW(NS)>1._EB) THEN ! FDS Tech Guide (5.55)
      DZ_IB=1._EB-ZZ_0(NS)
      DZ_OB=ZZ_NEW(NS)-1._EB
      BCOR = MIN( BCOR, DZ_IB/MAX(DZ_IB+DZ_OB,TWO_EPSILON_EB) )
   ENDIF
ENDDO
FUNC_BCOR = BCOR

END FUNCTION FUNC_BCOR


SUBROUTINE FIRE_RK2(ZZ_OUT,ZETA_OUT,ZZ_IN,ZETA_IN,DT_SUB,N_INC,TMP_MIXED,RHO_HAT,ZZ_UNMIXED,CELL_MASS,TAU_MIX)
! This function uses RK2 to integrate ZZ_O from t=0 to t=DT_SUB in increments of DT_LOC=DT_SUB/N_INC

REAL(EB), INTENT(IN) :: ZZ_IN(0:N_TRACKED_SPECIES),DT_SUB,ZETA_IN,TMP_MIXED,RHO_HAT,ZZ_UNMIXED(0:N_TRACKED_SPECIES),CELL_MASS,&
                        TAU_MIX
REAL(EB), INTENT(OUT) :: ZZ_OUT(0:N_TRACKED_SPECIES),ZETA_OUT
INTEGER, INTENT(IN) :: N_INC
REAL(EB) :: DT_LOC,ZZ_0(0:N_TRACKED_SPECIES),ZZ_1(0:N_TRACKED_SPECIES),ZZ_2(0:N_TRACKED_SPECIES),ZETA_0,ZETA_1,ZETA_2
INTEGER :: N

DT_LOC = DT_SUB/REAL(N_INC,EB)
ZZ_0 = ZZ_IN
ZETA_0 = ZETA_IN
DO N=1,N_INC
   CALL FIRE_FORWARD_EULER(ZZ_1,ZETA_1,ZZ_0,ZETA_0,DT_LOC,TMP_MIXED,RHO_HAT,ZZ_UNMIXED,CELL_MASS,TAU_MIX) 
   CALL FIRE_FORWARD_EULER(ZZ_2,ZETA_2,ZZ_1,ZETA_1,DT_LOC,TMP_MIXED,RHO_HAT,ZZ_UNMIXED,CELL_MASS,TAU_MIX)  
   ZZ_OUT = 0.5_EB*(ZZ_0 + ZZ_2)
   ZZ_0 = ZZ_OUT
   ZETA_OUT = ZETA_1
   ZETA_0 = ZETA_OUT
ENDDO

END SUBROUTINE FIRE_RK2


SUBROUTINE REACTION_RATE(DZZ,ZZ_0,DT_LOC,RHO_0,TMP_0,KINETICS)
USE PHYSICAL_FUNCTIONS, ONLY : GET_MASS_FRACTION_ALL,GET_SPECIFIC_GAS_CONSTANT,GET_GIBBS_FREE_ENERGY,GET_MOLECULAR_WEIGHT
REAL(EB), INTENT(OUT) :: DZZ(0:N_TRACKED_SPECIES)
REAL(EB), INTENT(IN) :: ZZ_0(0:N_TRACKED_SPECIES),DT_LOC,RHO_0,TMP_0
INTEGER, INTENT(IN) :: KINETICS
REAL(EB) :: DZ_F(1:N_REACTIONS),YY_PRIMITIVE(1:N_SPECIES),DG_RXN,MW,MOLPCM3,MIXFR,FFF,FOF,FFT,FOT,MIXFR_ST,&
            LFminY,LFmaxY,LOmaxY,LFminB,LFmaxB,LOmaxB,LFminC,LFmaxC,LOmaxC,TMP_02
INTEGER :: I,NS
INTEGER, PARAMETER :: INFINITELY_FAST=1,FINITE_RATE=2
TYPE(REACTION_TYPE),POINTER :: RN=>NULL(), RNP=>NULL()

DZ_F = 0._EB
DZZ = 0._EB
TMP_02=TMP_0

KINETICS_SELECT: SELECT CASE(KINETICS)
   
   CASE(INFINITELY_FAST)
      IF (EXTINCT) RETURN
      REACTION_LOOP_1: DO I=1,N_REACTIONS
         RN => REACTION(I)
         IF (.NOT.RN%FAST_CHEMISTRY) CYCLE REACTION_LOOP_1
         
         !Cambios para soot
         IF (CAMBIO) THEN
            TMP_02=TMP_0*(DX(1)/0.0025_EB*CT-CT+1)
            LOmaxC=0._EB*(DX(1)/0.0025_EB*COX-COX+1)
            IF (RN%ID=='ox1C') THEN
	   		   IF (TMP_02<1300._EB .OR. YY_PRIMITIVE(1)*RNP%S-YY_PRIMITIVE(3)>LOmaxC) THEN
			      CYCLE REACTION_LOOP_1				
			   ENDIF
            ENDIF           
         ENDIF
         DZ_F(I) = ZZ_0(RN%FUEL_SMIX_INDEX)
         DZZ = DZZ + RN%NU_MW_O_MW_F*DZ_F(I)
      ENDDO REACTION_LOOP_1

   CASE(FINITE_RATE) 
      REACTION_LOOP_2: DO I=1,N_REACTIONS
         RN => REACTION(I)

         IF (RN%FAST_CHEMISTRY .OR. ZZ_0(RN%FUEL_SMIX_INDEX) < ZZ_MIN_GLOBAL) CYCLE REACTION_LOOP_2
         IF (RN%AIR_SMIX_INDEX > -1 .AND. RN%ID/='oxB_n') THEN
            IF (ZZ_0(RN%AIR_SMIX_INDEX) < ZZ_MIN_GLOBAL) CYCLE REACTION_LOOP_2 ! no expected air
         ENDIF
         CALL GET_MASS_FRACTION_ALL(ZZ_0,YY_PRIMITIVE)
         DO NS=1,N_SPECIES
            IF(RN%N_S(NS)>= -998._EB .AND. YY_PRIMITIVE(NS) < ZZ_MIN_GLOBAL) CYCLE REACTION_LOOP_2
         ENDDO
         
         !Cambios para soot
         IF (CAMBIO) THEN
            TMP_02=TMP_0*(DX(1)/0.0025_EB*CT-CT+1)
            LFminY=0.1617_EB*(-DX(1)/0.0025_EB*CF+CF+1)
            LFmaxY=0.3495_EB*(DX(1)/0.0025_EB*CF-CF+1)
            LOmaxY=0.3495_EB*(DX(1)/0.0025_EB*COX-COX+1)
            LFminB=0.059395684_EB*(-DX(1)/0.0025_EB*CF+CF+1)
            LFmaxB=0.3495_EB*(DX(1)/0.0025_EB*CF-CF+1)
            LOmaxB=0.059395684_EB*(DX(1)/0.0025_EB*COX-COX+1)
            LFminC=0._EB*(-DX(1)/0.0025_EB*CF+CF+1)
            LFmaxC=0.3495_EB*(DX(1)/0.0025_EB*CF-CF+1)
            RNP => REACTION(1)
            
            IF (RN%ID=='form1Yao' .OR. RN%ID=='form2Yao') THEN
!~                            WRITE(LU_ERR,*) 'R ', R0, 'E/R', RN%E/R0
   			   IF (YY_PRIMITIVE(1)*RNP%S-YY_PRIMITIVE(3)<LFminY .OR. YY_PRIMITIVE(1)*RNP%S-YY_PRIMITIVE(3)>LFmaxY) THEN
	   			  CYCLE REACTION_LOOP_2
			   ENDIF
			ENDIF
            IF (RN%ID=='ox1' .OR. RN%ID=='ox2') THEN
	   		   IF (TMP_02<1300._EB .OR. YY_PRIMITIVE(1)*RNP%S-YY_PRIMITIVE(3)>LOmaxY) THEN
			      CYCLE REACTION_LOOP_2				
			   ENDIF
            ENDIF			
			
			IF (RN%ID=='form1B' .OR. RN%ID=='form2B') THEN
   			   IF (YY_PRIMITIVE(1)*RNP%S-YY_PRIMITIVE(3)<LFminB .OR. YY_PRIMITIVE(1)*RNP%S-YY_PRIMITIVE(3)>LFmaxB) THEN
	   			  CYCLE REACTION_LOOP_2
	   		   ENDIF
			ENDIF
            IF (RN%ID=='oxB') THEN
			    IF (TMP_02<1300._EB .OR. YY_PRIMITIVE(1)*RNP%S-YY_PRIMITIVE(3)>LOmaxB) THEN
				   CYCLE REACTION_LOOP_2			
			   ELSE
				   	   DZ_F(I) = 1/RHO_0
					   DZZ = DZZ + RN%NU_MW_O_MW_F*DZ_F(I)*DT_LOC
					   CYCLE REACTION_LOOP_2
			   ENDIF
            ENDIF			

			IF (RN%ID=='form1C' .OR. RN%ID=='form2C') THEN
   			   IF (YY_PRIMITIVE(1)*RNP%S-YY_PRIMITIVE(3)<LFminC .OR. YY_PRIMITIVE(1)*RNP%S-YY_PRIMITIVE(3)>LFmaxC) THEN
	   			  CYCLE REACTION_LOOP_2
			   ENDIF
			ENDIF
!~             IF (RN%ID=='ox1C') THEN
!~ 	   		   IF (TMP_02<1300._EB .OR. YY_PRIMITIVE(1)*RNP%S-YY_PRIMITIVE(3)>0._EB) THEN
!~ 			      CYCLE REACTION_LOOP_2				
!~ 			   ENDIF
!~             ENDIF             

			MIXFR_ST=(0.233)/(RNP%S+0.233)
            IF (RN%ID=='formLaut') THEN
			   MIXFR=(YY_PRIMITIVE(1)*RNP%S+0.233)/(RNP%S+0.233)
			   FFF=0
	       	   FFT=0
		       IF (MIXFR<1.05*MIXFR_ST .OR. MIXFR>2.15*MIXFR_ST) THEN
	    	      CYCLE REACTION_LOOP_2
			   ELSE
			      FFF=10.88746658-419.0146993*MIXFR+5120.769037*MIXFR**2-19284.77449*MIXFR**3			      
			   ENDIF
			   IF (TMP_02<1375 .OR. TMP_02>1825) THEN
			      CYCLE REACTION_LOOP_2
			   ELSE
				   FFT=31.3671875-0.0901875*TMP_02+0.0000765*TMP_02**2-0.00000002*TMP_02**3
			   ENDIF
			   DZ_F(I) = FFF*FFT/RHO_0
			   DZZ = DZZ + RN%NU_MW_O_MW_F*DZ_F(I)*DT_LOC
			   CYCLE REACTION_LOOP_2
            ENDIF
         
            IF (RN%ID=='oxLaut') THEN			
			   MIXFR=(YY_PRIMITIVE(1)*RNP%S-YY_PRIMITIVE(3)+0.233)/(RNP%S+0.233)
			   FOF=0
			   FOT=0
			   IF (MIXFR<0.56*MIXFR_ST .OR. MIXFR>1.05*MIXFR_ST) THEN
				   CYCLE REACTION_LOOP_2
			   ELSE
				   FOF=-1.66089E-14+158.7320734*MIXFR-6817.706306*MIXFR**2+66425.90228*MIXFR**3
			   ENDIF
			   IF (TMP_02<1375) THEN
				   CYCLE REACTION_LOOP_2
			   ELSE
				   FOT=0.006*TMP_02-8.25
			   ENDIF
			   DZ_F(I) = -1*FOF*FOT/RHO_0
			   DZZ = DZZ + RN%NU_MW_O_MW_F*DZ_F(I)*DT_LOC
			   CYCLE REACTION_LOOP_2
            ENDIF
         ENDIF
!~                                     WRITE(LU_ERR,*) 'llega'
         DZ_F(I) = RN%A_PRIME*RHO_0**RN%RHO_EXPONENT*TMP_02**RN%N_T*EXP(-RN%E/(R0*TMP_02)) ! FDS Tech Guide, Eq. (5.49)
         DO NS=1,N_SPECIES
            IF(RN%N_S(NS)>= -998._EB)  DZ_F(I) = YY_PRIMITIVE(NS)**RN%N_S(NS)*DZ_F(I)
         ENDDO
         IF (RN%THIRD_BODY) THEN
            CALL GET_MOLECULAR_WEIGHT(ZZ_0,MW)
            MOLPCM3 = RHO_0/MW*0.001_EB ! mol/cm^3
            DZ_F(I) = DZ_F(I) * MOLPCM3
         ENDIF
         IF(RN%REVERSE) THEN ! compute equilibrium constant
            CALL GET_GIBBS_FREE_ENERGY(DG_RXN,RN%NU,TMP_02)
            RN%K = EXP(-DG_RXN/(R0*TMP_02))
         ENDIF
         IF (CAMBIO .AND. (RN%ID=='form1Yao' .OR. RN%ID=='form1B' .OR. RN%ID=='form1C')) THEN
            DZ_F(I) =DZ_F(I)*RHO_0
         ENDIF
         DZZ = DZZ + RN%NU_MW_O_MW_F*DZ_F(I)*DT_LOC/RN%K
!~          WRITE(LU_ERR,*) DZZ
      ENDDO REACTION_LOOP_2      

END SELECT KINETICS_SELECT

END SUBROUTINE REACTION_RATE


LOGICAL FUNCTION FUNC_EXTINCT(ZZ_MIXED_IN,TMP_MIXED)
REAL(EB), INTENT(IN) :: ZZ_MIXED_IN(0:N_TRACKED_SPECIES),TMP_MIXED

FUNC_EXTINCT = .FALSE.
IF (ANY(REACTION(:)%FAST_CHEMISTRY)) THEN
   SELECT CASE (EXTINCT_MOD)
      CASE(EXTINCTION_1)
         FUNC_EXTINCT = EXTINCT_1(ZZ_MIXED_IN,TMP_MIXED)
      CASE(EXTINCTION_2)
         FUNC_EXTINCT = EXTINCT_2(ZZ_MIXED_IN,TMP_MIXED)
      CASE(EXTINCTION_3)
         FUNC_EXTINCT = .FALSE.
   END SELECT
ENDIF

END FUNCTION FUNC_EXTINCT


LOGICAL FUNCTION EXTINCT_1(ZZ_IN,TMP_MIXED)
USE PHYSICAL_FUNCTIONS,ONLY:GET_AVERAGE_SPECIFIC_HEAT
REAL(EB),INTENT(IN)::ZZ_IN(0:N_TRACKED_SPECIES),TMP_MIXED
REAL(EB):: Y_O2,Y_O2_CRIT,CPBAR
INTEGER :: NR
TYPE(REACTION_TYPE),POINTER :: RN=>NULL()

EXTINCT_1 = .FALSE.
REACTION_LOOP: DO NR=1,N_REACTIONS
   RN => REACTION(NR)
   IF (.NOT.RN%FAST_CHEMISTRY) CYCLE REACTION_LOOP
   AIT_IF: IF (TMP_MIXED < RN%AUTO_IGNITION_TEMPERATURE) THEN
      EXTINCT_1 = .TRUE.
   ELSE AIT_IF
      CALL GET_AVERAGE_SPECIFIC_HEAT(ZZ_IN,CPBAR,TMP_MIXED)
      Y_O2 = ZZ_IN(RN%AIR_SMIX_INDEX)
      Y_O2_CRIT = CPBAR*(RN%CRIT_FLAME_TMP-TMP_MIXED)/RN%EPUMO2
      IF (Y_O2 < Y_O2_CRIT) EXTINCT_1 = .TRUE.
   ENDIF AIT_IF
ENDDO REACTION_LOOP

END FUNCTION EXTINCT_1


LOGICAL FUNCTION EXTINCT_2(ZZ_MIXED_IN,TMP_MIXED)
USE PHYSICAL_FUNCTIONS,ONLY:GET_SENSIBLE_ENTHALPY
REAL(EB),INTENT(IN)::ZZ_MIXED_IN(0:N_TRACKED_SPECIES),TMP_MIXED
REAL(EB):: ZZ_F,ZZ_HAT_F,ZZ_GET_F(0:N_TRACKED_SPECIES),ZZ_A,ZZ_HAT_A,ZZ_GET_A(0:N_TRACKED_SPECIES),ZZ_P,ZZ_HAT_P,&
           ZZ_GET_P(0:N_TRACKED_SPECIES),H_F_0,H_A_0,H_P_0,H_F_N,H_A_N,H_P_N
INTEGER :: NR
TYPE(REACTION_TYPE),POINTER :: RN=>NULL()

EXTINCT_2 = .FALSE.
REACTION_LOOP: DO NR=1,N_REACTIONS
   RN => REACTION(NR)
   IF (.NOT.RN%FAST_CHEMISTRY) CYCLE REACTION_LOOP
   AIT_IF: IF (TMP_MIXED < RN%AUTO_IGNITION_TEMPERATURE) THEN
      EXTINCT_2 = .TRUE.
   ELSE AIT_IF
      ZZ_F = ZZ_MIXED_IN(RN%FUEL_SMIX_INDEX)
      ZZ_A = ZZ_MIXED_IN(RN%AIR_SMIX_INDEX)
      ZZ_P = 1._EB - ZZ_F - ZZ_A

      ZZ_HAT_F = MIN(ZZ_F,ZZ_MIXED_IN(RN%AIR_SMIX_INDEX)/RN%S) ! burned fuel, FDS Tech Guide (5.16)
      ZZ_HAT_A = ZZ_HAT_F*RN%S ! FDS Tech Guide (5.17)
      ZZ_HAT_P = (ZZ_HAT_A/(ZZ_A+TWO_EPSILON_EB))*(ZZ_F - ZZ_HAT_F + ZZ_P) ! reactant diluent concentration, FDS Tech Guide (5.18)

      ! "GET" indicates a composition vector.  Below we are building up the masses of the constituents in the various
      ! mixtures.  At this point these composition vectors are not normalized.

      ZZ_GET_F = 0._EB
      ZZ_GET_A = 0._EB
      ZZ_GET_P = ZZ_MIXED_IN

      ZZ_GET_F(RN%FUEL_SMIX_INDEX) = ZZ_HAT_F ! fuel in reactant mixture composition
      ZZ_GET_A(RN%AIR_SMIX_INDEX)  = ZZ_HAT_A ! air  in reactant mixture composition
   
      ZZ_GET_P(RN%FUEL_SMIX_INDEX) = MAX(ZZ_GET_P(RN%FUEL_SMIX_INDEX)-ZZ_HAT_F,0._EB) ! remove burned fuel from product composition
      ZZ_GET_P(RN%AIR_SMIX_INDEX)  = MAX(ZZ_GET_P(RN%AIR_SMIX_INDEX) -ZZ_A,0._EB) ! remove all air from product composition
   
      ! Normalize concentrations
      ZZ_GET_F = ZZ_GET_F/(SUM(ZZ_GET_F)+TWO_EPSILON_EB)
      ZZ_GET_A = ZZ_GET_A/(SUM(ZZ_GET_A)+TWO_EPSILON_EB)
      ZZ_GET_P = ZZ_GET_P/(SUM(ZZ_GET_P)+TWO_EPSILON_EB)

      ! Get the specific heat for the fuel and diluent at the current and critical flame temperatures
      CALL GET_SENSIBLE_ENTHALPY(ZZ_GET_F,H_F_0,TMP_MIXED)
      CALL GET_SENSIBLE_ENTHALPY(ZZ_GET_A,H_A_0,TMP_MIXED)
      CALL GET_SENSIBLE_ENTHALPY(ZZ_GET_P,H_P_0,TMP_MIXED) 
      CALL GET_SENSIBLE_ENTHALPY(ZZ_GET_F,H_F_N,RN%CRIT_FLAME_TMP)
      CALL GET_SENSIBLE_ENTHALPY(ZZ_GET_A,H_A_N,RN%CRIT_FLAME_TMP)
      CALL GET_SENSIBLE_ENTHALPY(ZZ_GET_P,H_P_N,RN%CRIT_FLAME_TMP)  
   
      ! See if enough energy is released to raise the fuel and required "air" temperatures above the critical flame temp. 
      IF ( ZZ_HAT_F*(H_F_0 + RN%HEAT_OF_COMBUSTION) + ZZ_HAT_A*H_A_0 + ZZ_HAT_P*H_P_0 < &
         ZZ_HAT_F*H_F_N  + ZZ_HAT_A*H_A_N + ZZ_HAT_P*H_P_N ) EXTINCT_2 = .TRUE. ! FDS Tech Guide (5.19)
   ENDIF AIT_IF
ENDDO REACTION_LOOP

END FUNCTION EXTINCT_2


LOGICAL FUNCTION EXTINCT_3(ZZ_MIXED_IN,TMP_MIXED)
USE PHYSICAL_FUNCTIONS,ONLY:GET_SENSIBLE_ENTHALPY
REAL(EB),INTENT(IN)::ZZ_MIXED_IN(0:N_TRACKED_SPECIES),TMP_MIXED
REAL(EB):: H_F_0,H_A_0,H_P_0,H_P_N,Z_F,Z_A,Z_P,Z_A_STOICH,ZZ_HAT_F,ZZ_HAT_A,ZZ_HAT_P,&
           ZZ_GET_F(0:N_TRACKED_SPECIES),ZZ_GET_A(0:N_TRACKED_SPECIES),ZZ_GET_P(0:N_TRACKED_SPECIES),ZZ_GET_F_REAC(1:N_REACTIONS),&
           ZZ_GET_PFP(0:N_TRACKED_SPECIES),DZ_F(1:N_REACTIONS),DZ_FRAC_F(1:N_REACTIONS),DZ_F_SUM,&
           HOC_EXTINCT,AIT_EXTINCT,CFT_EXTINCT
INTEGER :: NS,NR
TYPE(REACTION_TYPE),POINTER :: RN=>NULL()

EXTINCT_3 = .FALSE.
Z_F = 0._EB
Z_A = 0._EB
Z_P = 0._EB
DZ_F = 0._EB
DZ_F_SUM = 0._EB
Z_A_STOICH = 0._EB
ZZ_GET_F = 0._EB
ZZ_GET_A = 0._EB
ZZ_GET_P = ZZ_MIXED_IN
ZZ_GET_PFP = 0._EB
HOC_EXTINCT = 0._EB
AIT_EXTINCT = 0._EB
CFT_EXTINCT = 0._EB

DO NS=0,N_TRACKED_SPECIES
   SUM_FUEL_LOOP: DO NR = 1,N_REACTIONS
      RN => REACTION(NR)
      IF (RN%FAST_CHEMISTRY .AND. RN%HEAT_OF_COMBUSTION > 0._EB .AND. NS == RN%FUEL_SMIX_INDEX) THEN
         Z_F = Z_F + ZZ_MIXED_IN(NS)
         EXIT SUM_FUEL_LOOP
      ENDIF
   ENDDO SUM_FUEL_LOOP
   SUM_AIR_LOOP: DO NR = 1,N_REACTIONS
      RN => REACTION(NR)
      IF (RN%FAST_CHEMISTRY .AND. RN%HEAT_OF_COMBUSTION > 0._EB .AND. RN%NU(NS) < 0._EB .AND. NS /= RN%FUEL_SMIX_INDEX) THEN
         Z_A = Z_A + ZZ_MIXED_IN(NS)
         ZZ_GET_P(NS) = MAX(ZZ_GET_P(NS) - ZZ_MIXED_IN(NS),0._EB)
         EXIT SUM_AIR_LOOP
      ENDIF
   ENDDO SUM_AIR_LOOP
ENDDO
Z_P = 1._EB - Z_F - Z_A
DO NR = 1,N_REACTIONS
   RN => REACTION(NR)
   IF (RN%FAST_CHEMISTRY .AND. RN%HEAT_OF_COMBUSTION > 0._EB) THEN
      DZ_F(NR) = 1.E10_EB
      DO NS = 0,N_TRACKED_SPECIES
         IF (RN%NU(NS) < 0._EB) THEN
            DZ_F(NR) = MIN(DZ_F(NR),-ZZ_MIXED_IN(NS)/RN%NU_MW_O_MW_F(NS))
         ENDIF
         IF (RN%NU(NS) < 0._EB .AND. NS /= RN%FUEL_SMIX_INDEX) THEN
            Z_A_STOICH = Z_A_STOICH + ZZ_MIXED_IN(RN%FUEL_SMIX_INDEX)*RN%S
         ENDIF
      ENDDO
   ENDIF
ENDDO
IF (Z_A_STOICH > Z_A) DZ_F_SUM = SUM(DZ_F)
DO NR = 1,N_REACTIONS
   RN => REACTION(NR) 
   IF (Z_A_STOICH > Z_A .AND. RN%HEAT_OF_COMBUSTION > 0._EB) THEN 
      DZ_FRAC_F(NR) = DZ_F(NR)/MAX(DZ_F_SUM,TWO_EPSILON_EB)
      ZZ_GET_F(RN%FUEL_SMIX_INDEX) = DZ_F(NR)*DZ_FRAC_F(NR)
      ZZ_GET_P(RN%FUEL_SMIX_INDEX) = ZZ_GET_P(RN%FUEL_SMIX_INDEX) - ZZ_GET_F(RN%FUEL_SMIX_INDEX)
      ZZ_GET_PFP(RN%FUEL_SMIX_INDEX) = ZZ_GET_P(RN%FUEL_SMIX_INDEX)
      DO NS = 0,N_TRACKED_SPECIES
         IF (RN%NU(NS)< 0._EB .AND. NS/=RN%FUEL_SMIX_INDEX) THEN
            ZZ_GET_A(NS) = RN%S*ZZ_GET_F(RN%FUEL_SMIX_INDEX)
!            ZZ_GET_P(NS) = ZZ_GET_P(NS) - ZZ_GET_A(NS)
            ZZ_GET_PFP(NS) = ZZ_GET_P(NS)
         ELSEIF (RN%NU(NS) >= 0._EB ) THEN
            ZZ_GET_PFP(NS) = ZZ_GET_P(NS) + ZZ_GET_F(RN%FUEL_SMIX_INDEX)*RN%NU_MW_O_MW_F(NS)
         ENDIF
      ENDDO
   ELSE
      ZZ_GET_F(RN%FUEL_SMIX_INDEX) = DZ_F(NR)
      ZZ_GET_P(RN%FUEL_SMIX_INDEX) = ZZ_GET_P(RN%FUEL_SMIX_INDEX) - ZZ_GET_F(RN%FUEL_SMIX_INDEX)
      ZZ_GET_PFP(RN%FUEL_SMIX_INDEX) = ZZ_GET_P(RN%FUEL_SMIX_INDEX)
      DO NS = 0,N_TRACKED_SPECIES
         IF (RN%NU(NS) < 0._EB .AND. NS/=RN%FUEL_SMIX_INDEX) THEN
            ZZ_GET_A(NS) = RN%S*ZZ_GET_F(RN%FUEL_SMIX_INDEX)
!            ZZ_GET_P(NS) = ZZ_GET_P(NS) - ZZ_GET_A(NS)
            ZZ_GET_PFP(NS) = ZZ_GET_P(NS)
         ELSEIF (RN%NU(NS) >= 0._EB ) THEN
            ZZ_GET_PFP(NS) = ZZ_GET_P(NS) + ZZ_GET_F(RN%FUEL_SMIX_INDEX)*RN%NU_MW_O_MW_F(NS)
         ENDIF
      ENDDO
   ENDIF
   ZZ_GET_F_REAC(NR) = ZZ_GET_F(RN%FUEL_SMIX_INDEX)
ENDDO

ZZ_HAT_F = SUM(ZZ_GET_F)
ZZ_HAT_A = SUM(ZZ_GET_A)
ZZ_HAT_P = (ZZ_HAT_A/(Z_A+TWO_EPSILON_EB))*(Z_F-ZZ_HAT_F+SUM(ZZ_GET_P))
!M_P_ST = SUM(ZZ_GET_P)

! Normalize compositions
ZZ_GET_F = ZZ_GET_F/(SUM(ZZ_GET_F)+TWO_EPSILON_EB)
ZZ_GET_F_REAC = ZZ_GET_F_REAC/(SUM(ZZ_GET_F_REAC)+TWO_EPSILON_EB)
ZZ_GET_A = ZZ_GET_A/(SUM(ZZ_GET_A)+TWO_EPSILON_EB)
ZZ_GET_P = ZZ_GET_P/(SUM(ZZ_GET_P)+TWO_EPSILON_EB)
ZZ_GET_PFP = ZZ_GET_PFP/(SUM(ZZ_GET_PFP)+TWO_EPSILON_EB)

DO NR = 1,N_REACTIONS
   RN => REACTION(NR)
   AIT_EXTINCT = AIT_EXTINCT+ZZ_GET_F_REAC(NR)*RN%AUTO_IGNITION_TEMPERATURE
   CFT_EXTINCT = CFT_EXTINCT+ZZ_GET_F_REAC(NR)*RN%CRIT_FLAME_TMP
   HOC_EXTINCT = HOC_EXTINCT+ZZ_GET_F_REAC(NR)*RN%HEAT_OF_COMBUSTION
ENDDO
   
IF (TMP_MIXED < AIT_EXTINCT) THEN
   EXTINCT_3 = .TRUE.
ELSE     
   ! Get the specific heat for the fuel and diluent at the current and critical flame temperatures
   CALL GET_SENSIBLE_ENTHALPY(ZZ_GET_F,H_F_0,TMP_MIXED)
   CALL GET_SENSIBLE_ENTHALPY(ZZ_GET_A,H_A_0,TMP_MIXED)
   CALL GET_SENSIBLE_ENTHALPY(ZZ_GET_P,H_P_0,TMP_MIXED)  
   CALL GET_SENSIBLE_ENTHALPY(ZZ_GET_PFP,H_P_N,CFT_EXTINCT)
   
   ! See if enough energy is released to raise the fuel and required "air" temperatures above the critical flame temp. 
   IF (ZZ_HAT_F*(H_F_0+HOC_EXTINCT) + ZZ_HAT_A*H_A_0 + ZZ_HAT_P*H_P_0 < &
      (ZZ_HAT_F+ZZ_HAT_A+ZZ_HAT_P)*H_P_N) EXTINCT_3 = .TRUE. ! FED Tech Guide (5.19)
ENDIF

END FUNCTION EXTINCT_3


SUBROUTINE GET_REV_fire(MODULE_REV,MODULE_DATE)
INTEGER,INTENT(INOUT) :: MODULE_REV
CHARACTER(255),INTENT(INOUT) :: MODULE_DATE

WRITE(MODULE_DATE,'(A)') firerev(INDEX(firerev,':')+2:LEN_TRIM(firerev)-2)
READ (MODULE_DATE,'(I5)') MODULE_REV
WRITE(MODULE_DATE,'(A)') firedate

END SUBROUTINE GET_REV_fire

 
END MODULE FIRE

